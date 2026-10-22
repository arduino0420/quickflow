require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "PDF checks before AI file creation" do
  include_context "AI grading records"

  def broken_blob(attachment)
    attachment.attach(io: StringIO.new("%PDF-1.7\ninvalid"), filename: "broken.pdf", content_type: "application/pdf")
  end

  it "rejects unreadable selected material before constructing or calling an AI client" do
    broken_blob(assignment.material_file)
    request = QuestionGenerationRequest.select_for_distribution!(assignment, model: "captured-pdf-model")
    expect(AiClient).not_to receive(:build)
    expect(files).not_to receive(:create)
    expect { QuestionGenerator.new(client: client, model: "other-model").call(assignment, request_id: request.id) }
      .to raise_error(PdfReadabilityValidator::InvalidPdf)
    expect(request.reload).to have_attributes(state: "failed", failure_code: "generation_failed", model: "captured-pdf-model")
    expect(request.finished_at).to be_present
  end

  it "rejects unreadable legacy answers before files.create" do
    broken_blob(submission.answer_file)
    expect(files).not_to receive(:create)
    expect { AnswerReader.new(client: client).call(submission) }.to raise_error(PdfReadabilityValidator::InvalidPdf)
  end

  it "uses the selected durable question request failure state" do
    broken_blob(assignment.material_file)
    request = QuestionGenerationRequest.select_for_distribution!(assignment, model: "captured-pdf-model")
    expect(AiClient).not_to receive(:build)
    expect(files).not_to receive(:create)
    QuestionGenerationJob.perform_now(assignment, request.material_blob_id, 0, request_id: request.id)
    expect(request.reload).to have_attributes(state: "failed", failure_code: "generation_failed", model: "captured-pdf-model")
    expect(QuestionGenerator.new(model: "other-model").failed?(assignment)).to be(true)
  end

  it "keeps legacy unknown intent closed without parsing or creating a request" do
    broken_blob(assignment.material_file)
    expect(PdfReadabilityValidator).not_to receive(:validate!)
    expect(AiClient).not_to receive(:build)
    expect do
      expect { QuestionGenerator.new.call(assignment) }.to raise_error(/history is unknown/)
      QuestionGenerationJob.perform_now(assignment, assignment.material_file.blob.id)
    end.not_to change(QuestionGenerationRequest, :count)
  end

  it "leaves stale request jobs fenced before the PDF check and current-request failure" do
    old_request = QuestionGenerationRequest.select_for_distribution!(assignment, model: "old-model")
    broken_blob(assignment.material_file)
    selected = QuestionGenerationRequest.select_for_distribution!(assignment, model: "captured-pdf-model")
    expect(PdfReadabilityValidator).not_to receive(:validate!)
    expect(AiClient).not_to receive(:build)
    QuestionGenerationJob.perform_now(assignment, old_request.material_blob_id, 0, request_id: old_request.id)
    expect(old_request.reload.state).to eq("pending")
    expect(selected.reload.state).to eq("pending")
    expect(assignment.reload.current_question_generation_request_id).to eq(selected.id)
  end

  it "uses the existing answer job failed status" do
    broken_blob(submission.answer_file)
    submission.update!(extracted_text: nil)
    allow(AiClient).to receive(:build).and_return(client)
    expect(files).not_to receive(:create)
    AnswerReadingJob.perform_now(submission)
    expect(submission.reload).to be_failed
  end

  it "does not disturb reuse of already saved questions" do
    question = create_question
    expect(PdfReadabilityValidator).not_to receive(:validate!)
    expect(AiClient).not_to receive(:build)
    expect(QuestionGenerator.new.call(assignment)).to eq([ question ])
  end
end
