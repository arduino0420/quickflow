require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "PDF checks before AI file creation" do
  include_context "AI grading records"

  def broken_blob(attachment)
    attachment.attach(io: StringIO.new("%PDF-1.7\ninvalid"), filename: "broken.pdf", content_type: "application/pdf")
  end

  it "rejects unreadable legacy material before constructing or calling an AI client" do
    broken_blob(assignment.material_file)
    expect(AiClient).not_to receive(:build)
    expect(files).not_to receive(:create)
    expect { QuestionGenerator.new(client: client).call(assignment) }.to raise_error(PdfReadabilityValidator::InvalidPdf)
  end

  it "rejects unreadable legacy answers before files.create" do
    broken_blob(submission.answer_file)
    expect(files).not_to receive(:create)
    expect { AnswerReader.new(client: client).call(submission) }.to raise_error(PdfReadabilityValidator::InvalidPdf)
  end

  it "uses the existing question job failure cache" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    broken_blob(assignment.material_file)
    expect(AiClient).not_to receive(:build)
    QuestionGenerationJob.perform_now(assignment, assignment.material_file.blob.id)
    expect(QuestionGenerator.new.failed?(assignment)).to be(true)
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
