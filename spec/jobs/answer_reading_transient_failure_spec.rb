require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "Answer reading transient failures", type: :job do
  include_context "AI grading records"
  include ActiveJob::TestHelper

  def unavailable
    OpenAI::Errors::InternalServerError.new(url: URI("https://example.invalid"), status: 503,
      headers: { "x-request-id" => "req_synthetic" }, body: "PRIVATE ANSWER", request: nil, response: nil)
  end

  before do
    submission.update!(extracted_text: nil)
    submission.answer_file.attach(io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      filename: "answer.pdf", content_type: "application/pdf")
    allow(AiClient).to receive(:build).and_return(client)
    allow(files).to receive(:create).and_return(double(id: "file-synthetic"))
    allow(responses).to receive(:create).and_return(ai_response(problems: [ problem ]))
    allow_any_instance_of(AnswerReadingRequest).to receive(:sleep)
    allow(Rails.logger).to receive(:warn)
  end

  it "recovers from a reading 5xx using the same upload and enqueues grading once" do
    calls = 0
    allow(responses).to receive(:create) do
      calls += 1
      raise unavailable if calls == 1

      ai_response(problems: [ problem ])
    end
    expect { AnswerReadingJob.perform_now(submission) }.to have_enqueued_job(AnswerGradingJob).once
    expect(files).to have_received(:create).once
    expect(responses).to have_received(:create).twice
    expect(submission.reload.extracted_text).to be_present
    expect(submission.answer_file).to be_attached
  end

  it "fails after one extra upload attempt and retains the saved answer" do
    blob_id = submission.answer_file.blob.id
    allow(files).to receive(:create).and_raise(unavailable)
    expect(responses).not_to receive(:create)
    expect { AnswerReadingJob.perform_now(submission) }.not_to have_enqueued_job(AnswerGradingJob)
    expect(files).to have_received(:create).twice
    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to be_nil
    expect(submission.answer_file.blob.id).to eq(blob_id)
  end

  it "does not admit a duplicate worker during backoff" do
    calls = 0
    allow(responses).to receive(:create) do
      calls += 1
      raise unavailable if calls == 1

      ai_response(problems: [ problem ])
    end
    allow_any_instance_of(AnswerReadingRequest).to receive(:sleep) do
      AnswerReadingJob.perform_now(Submission.find(submission.id))
    end
    AnswerReadingJob.perform_now(submission)
    expect(files).to have_received(:create).once
    expect(responses).to have_received(:create).twice
    expect(submission.reload.extracted_text).to be_present
  end

  it "does not retry or overwrite a newer generation" do
    allow(responses).to receive(:create) do
      submission.reload.update!(processing_generation: 1)
      raise unavailable
    end
    AnswerReadingJob.perform_now(submission)
    expect(responses).to have_received(:create).once
    expect(submission.reload.processing_generation).to eq(1)
    expect(submission).to be_grading
    expect(submission.extracted_text).to be_nil
  end

  it "does not issue a reading request after deletion during upload" do
    allow(files).to receive(:create) do
      Submission.where(id: submission.id).delete_all
      double(id: "file-synthetic")
    end
    expect(responses).not_to receive(:create)
    expect { AnswerReadingJob.perform_now(submission) }.not_to have_enqueued_job(AnswerGradingJob)
    expect(AiFileCleanupJob).to have_been_enqueued.with("file-synthetic")
  end
end
