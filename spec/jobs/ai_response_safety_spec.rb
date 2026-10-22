require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "AI response and error log safety", type: :job do
  include_context "AI grading records"

  let(:question) { create_question }
  let(:private_text) { "PRIVATE_SYNTHETIC_ANSWER_AND_API_ERROR" }
  let(:logged_errors) { [] }

  before do
    allow(AiClient).to receive(:build).and_return(client)
    allow(files).to receive(:create).and_return(double(id: "stub-file"))
    allow(responses).to receive(:create)
    allow(Rails.logger).to receive(:error) { |message| logged_errors << message }
  end

  def sdk_response(data, **changes)
    attributes = {
      status: "completed", model: "sdk-stub", error: nil, incomplete_details: nil,
      output: [ { type: "reasoning", id: "rs-stub", summary: [] },
        { type: "message", id: "msg-stub", role: "assistant", status: "completed",
        content: [ { type: "output_text", text: JSON.generate(data), annotations: [] } ] } ]
    }.merge(changes)
    OpenAI::Internal::Type::Converter.coerce(OpenAI::Models::Responses::Response, attributes)
  end

  [ :reading, :grading ].each do |stage|
    context "during #{stage}" do
      let(:job_class) { stage == :reading ? AnswerReadingJob : AnswerGradingJob }
      let(:data) { stage == :reading ? { problems: [ problem ] } : { results: [ judgment(question) ] } }

      before do
        if stage == :reading
          submission.update!(extracted_text: nil)
          submission.answer_file.attach(io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
            filename: "answer.pdf", content_type: "application/pdf")
        else
          question
          # This local needs_review result must not be partially saved if AI fails.
          create_question(position: 2, label: "1(2)")
        end
      end

      def expect_failed_without_partial_results
        expect(submission.reload).to be_failed
        expect(submission.grading_results).to be_empty
        expect(submission.score).to be_nil
        expect(submission.extracted_text).to be_nil if job_class == AnswerReadingJob
      end

      [ "completed", :completed ].each do |status|
        it "accepts completed status #{status.inspect} with the real SDK output shape" do
          response = sdk_response(data)
          expect(response.status).to eq(:completed)
          allow(response).to receive(:status).and_return(status)
          allow(responses).to receive(:create).and_return(response)

          job_class.perform_now(submission)

          if stage == :reading
            expect(submission.reload).to be_grading
            expect(JSON.parse(submission.extracted_text)).to eq(JSON.parse(JSON.generate(data)))
            expect(AnswerGradingJob).to have_been_enqueued.with(submission, 0, admission: kind_of(String))
          else
            expect(submission.reload).to be_completed
            expect(submission.grading_results.map(&:final_judgment)).to contain_exactly("correct", "needs_review")
            expect(submission.score).to eq(5)
          end
        end
      end

      [ :incomplete, :failed, :cancelled, :in_progress, :queued, :unknown, :missing_status,
        :missing_output, :missing_status_method, :missing_output_method, :missing_error_method, :missing_details_method,
        :error_with_completed, :incomplete_details_with_completed, :refusal ].each do |failure|
        it "rejects #{failure} before reading otherwise valid JSON and saves no partial results" do
          response = case failure
          when :missing_status
            sdk_response(data, status: nil)
          when :missing_output
            sdk_response(data, output: nil)
          when :missing_status_method, :missing_output_method, :missing_error_method, :missing_details_method
            fields = { status: :completed, output_text: JSON.generate(data), output: [], error: nil, incomplete_details: nil }
            missing = { missing_status_method: :status, missing_output_method: :output,
              missing_error_method: :error, missing_details_method: :incomplete_details }.fetch(failure)
            double(**fields.except(missing))
          when :error_with_completed
            sdk_response(data, error: { code: "server_error", message: private_text })
          when :incomplete_details_with_completed
            sdk_response(data, incomplete_details: { reason: "max_output_tokens" })
          when :refusal
            valid = { type: "output_text", text: JSON.generate(data), annotations: [] }
            sdk_response(data, output: [ { type: "message", id: "msg-refused", role: "assistant", status: "completed",
              content: [ valid, { type: "refusal", refusal: private_text } ] } ])
          else
            sdk_response(data, status: failure.to_s)
          end
          allow(response).to receive(:output_text).and_return(JSON.generate(data))
          allow(responses).to receive(:create).and_return(response)
          original_reading = submission.extracted_text

          expect { job_class.perform_now(submission) }.not_to have_enqueued_job(AnswerGradingJob)

          expect_failed_without_partial_results
          expect(submission.extracted_text).to eq(original_reading)
          expect(response).not_to have_received(:output_text)
          expect(responses).to have_received(:create).once
          expect(logged_errors.join).not_to include(private_text)
        end
      end

      it "does not log private exception text from the inner failure handler" do
        if stage == :reading
          allow(AnswerReader).to receive(:new).and_raise(StandardError, private_text)
        else
          allow(responses).to receive(:create).and_raise(StandardError, private_text)
        end

        job_class.perform_now(submission)

        expect_failed_without_partial_results
        expect(logged_errors).to contain_exactly("#{job_class} failed: submission_id=#{submission.id} StandardError")
        expect(logged_errors.join).not_to include(private_text)
      end

      it "does not log private exception text from the outer failure handler" do
        if stage == :reading
          # Exercise an error after the short claim has committed; the old
          # submission.with_lock instance is no longer the worker boundary.
          allow_any_instance_of(SubmissionProcessingClaim).to receive(:submission).and_raise(StandardError, private_text)
        else
          submission.update!(extracted_text: "{#{private_text}")
        end

        job_class.perform_now(submission)

        expect_failed_without_partial_results
        expect(logged_errors.size).to eq(1)
        expect(logged_errors.first).to start_with("#{job_class} failed: submission_id=#{submission.id} ")
        expect(logged_errors.join).not_to include(private_text)
        expect(responses).not_to have_received(:create)
      end
    end
  end
end
