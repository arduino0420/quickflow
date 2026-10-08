require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe QuestionGenerationJob, type: :job do
  include ActiveJob::TestHelper
  include_context "AI grading records"

  let(:generated_question) do
    { question_label: "1(1)", question_text: problem[:question_text], correct_answer: "5x",
      grading_rule: "同類項をまとめる。", requires_work: false }
  end

  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_cache
  end

  before do
    allow(AiClient).to receive(:build).and_return(client)
    allow(files).to receive(:create).and_return(double(id: "file-material"))
    allow(responses).to receive(:create).and_return(ai_response(questions: [ generated_question ]))
  end

  it "prepares answers without any students and reuses them when the job runs again" do
    blob_id = assignment.material_file.blob.id
    described_class.perform_now(assignment, blob_id)
    question_id = assignment.questions.sole.id
    described_class.perform_now(Assignment.find(assignment.id), blob_id)
    expect(assignment.questions.sole.id).to eq(question_id)
    expect(Submission.count).to eq(0)
    expect(files).to have_received(:create).once
    expect(responses).to have_received(:create).once
  end

  it "reuses existing valid answers without building a client" do
    question = create_question
    expect(AiClient).not_to receive(:build)
    described_class.perform_now(assignment, assignment.material_file.blob.id)
    expect(assignment.questions).to contain_exactly(question)
    expect(responses).not_to have_received(:create)
  end

  it "resumes a waiting submission using saved readings when generation finishes" do
    original_reading = submission.extracted_text
    AnswerGradingJob.perform_now(submission)
    expect(submission.reload).to be_grading
    expect(responses).not_to have_received(:create)
    expect(AnswerReader).not_to receive(:new)
    allow(responses).to receive(:create) do |request|
      if request[:instructions].include?("添付教材")
        ai_response(questions: [ generated_question ])
      else
        question_id = JSON.parse(request.fetch(:input)).fetch("problems").sole.fetch("question_id")
        ai_response(results: [ { question_id: question_id, ai_judgment: "correct", error_point: nil, feedback: nil, review_reason: nil } ])
      end
    end
    perform_enqueued_jobs(only: AnswerGradingJob) do
      described_class.perform_now(assignment, assignment.material_file.blob.id)
    end
    expect(submission.reload).to be_completed
    expect(submission.extracted_text).to eq(original_reading)
    expect(submission.grading_results.sole).to be_ai_judgment_correct
    expect(files).to have_received(:create).once
    expect(responses).to have_received(:create).twice
  end

  it "only schedules readable submissions that have not completed or failed" do
    submission.update!(extracted_text: nil)
    other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    completed = Submission.create!(assignment: assignment, student: other_student, submitted_at: Time.current,
      status: :completed, extracted_text: JSON.generate(problems: [ problem ]))
    failed_student = Student.create!(classroom: classroom, attendance_number: 3, password: "password123")
    failed = Submission.create!(assignment: assignment, student: failed_student, submitted_at: Time.current,
      status: :failed, extracted_text: JSON.generate(problems: [ problem ]))
    expect { described_class.perform_now(assignment, assignment.material_file.blob.id) }.not_to have_enqueued_job(AnswerGradingJob)
    expect(completed.reload).to be_completed
    expect(failed.reload).to be_failed
    expect(submission.reload.extracted_text).to be_nil
  end

  it "logs a timeout, preserves waiting readings, and does not repeat the generation request" do
    original_reading = submission.extracted_text
    error = OpenAI::Errors::APITimeoutError.new(url: URI("https://example.invalid"), message: "Timed out")
    allow(responses).to receive(:create).and_raise(error)
    allow(Rails.logger).to receive(:error)
    described_class.perform_now(assignment, assignment.material_file.blob.id)
    described_class.perform_now(Assignment.find(assignment.id), assignment.material_file.blob.id)
    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to eq(original_reading)
    expect(assignment.questions).to be_empty
    expect(Rails.logger).to have_received(:error).with(/QuestionGenerationJob failed: .*APITimeoutError\z/).once
    expect(files).to have_received(:create).once
    expect(responses).to have_received(:create).once
    expect(submission.grading_results).to be_empty
  end

  it "stops later submissions after generation failure without trying generation again" do
    allow(responses).to receive(:create).and_raise("API failed")
    described_class.perform_now(assignment, assignment.material_file.blob.id)
    AnswerGradingJob.perform_now(submission)
    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to be_present
    expect(responses).to have_received(:create).once
    expect(submission.grading_results).to be_empty
  end

  it "does not log AI output included in a parser error" do
    invalid_response = ai_response(questions: [ generated_question ])
    allow(invalid_response).to receive(:output_text).and_return("PRIVATE AI RESPONSE")
    allow(responses).to receive(:create).and_return(invalid_response)
    allow(Rails.logger).to receive(:error)
    described_class.perform_now(assignment, assignment.material_file.blob.id)
    expect(Rails.logger).to have_received(:error).with("QuestionGenerationJob failed: JSON::ParserError")
    expect(Rails.logger).not_to have_received(:error).with(/PRIVATE AI RESPONSE/)
    expect(assignment.questions).to be_empty
    expect(responses).to have_received(:create).once
  end

  it "stops on invalid stored answers without regenerating them" do
    create_question.update_columns(grading_rule: "invalid")
    original_reading = submission.extracted_text
    described_class.perform_now(assignment, assignment.material_file.blob.id)
    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to eq(original_reading)
    expect(assignment.questions.count).to eq(1)
    expect(files).not_to have_received(:create)
    expect(responses).not_to have_received(:create)
  end

  it "rejects a replaced PDF for a queued job without an API call" do
    blob_id = assignment.material_file.blob.id
    original_reading = submission.extracted_text
    assignment.material_file.attach(io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      filename: "replacement.pdf", content_type: "application/pdf")
    described_class.perform_now(assignment, blob_id)
    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to eq(original_reading)
    expect(files).not_to have_received(:create)
    expect(responses).not_to have_received(:create)
  end

  [ :exception, :rejected ].each do |failure|
    it "preserves prepared answers and readings after a #{failure} grading enqueue failure" do
      original_reading = submission.extracted_text
      if failure == :exception
        allow(AnswerGradingJob).to receive(:perform_later).and_raise("Queue unavailable")
      else
        allow(AnswerGradingJob).to receive(:perform_later).and_return(false)
      end
      allow(Rails.logger).to receive(:error)
      described_class.perform_now(assignment, assignment.material_file.blob.id)
      expect(submission.reload).to be_failed
      expect(submission.extracted_text).to eq(original_reading)
      expect(assignment.questions.count).to eq(1)
      expect(QuestionGenerator.new.failed?(assignment)).to be_falsey
      expect(Rails.logger).to have_received(:error).with(/QuestionGenerationJob grading enqueue failed/).once
      expect(responses).to have_received(:create).once
    end
  end
end
