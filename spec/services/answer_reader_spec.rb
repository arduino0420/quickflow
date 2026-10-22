require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe AnswerReader, type: :model do
  include_context "AI grading records"

  it "uses the configured reading model and preserves conservative reading instructions" do
    submission.answer_file.attach(io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      filename: "answer.pdf", content_type: "application/pdf")
    allow(files).to receive(:create).and_return(double(id: "file-answer"))
    allow(responses).to receive(:create).and_return(ai_response(problems: [ problem ]))
    reader = described_class.new(client: client, model: "reading-model")
    expect(AiFileCleanupJob).to receive(:schedule).with("file-answer")

    expect(JSON.parse(reader.call(submission))["problems"].first["student_answer"]).to eq("5x")
    expect(files).to have_received(:create).once.with(hash_including(
      purpose: "user_data", expires_after: { anchor: "created_at", seconds: 3600 }))
    expect(responses).to have_received(:create).once do |request|
      expect(request[:model]).to eq("reading-model")
      expect(request[:store]).to be(false)
      instructions = request[:input].first[:content].last[:text]
      expect(instructions).to include("補正・推測しない", "未記入と判読困難を区別", "訂正や候補が不明", "unavailable", "問題を解かず")
    end
  end

  it "schedules cleanup after a response error without changing the original error" do
    submission.answer_file.attach(io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      filename: "answer.pdf", content_type: "application/pdf")
    allow(files).to receive(:create).and_return(double(id: "file-answer"))
    allow(responses).to receive(:create).and_raise(Timeout::Error, "PRIVATE ANSWER")
    expect(AiFileCleanupJob).to receive(:schedule).with("file-answer")

    expect { described_class.new(client: client).call(submission) }.to raise_error(Timeout::Error, "PRIVATE ANSWER")
    expect(submission.answer_file).to be_attached
  end

  it "preserves the reading result when cleanup enqueue fails" do
    submission.answer_file.attach(io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      filename: "answer.pdf", content_type: "application/pdf")
    allow(files).to receive(:create).and_return(double(id: "file-answer"))
    allow(responses).to receive(:create).and_return(ai_response(problems: [ problem ]))
    allow(AiFileCleanupJob).to receive(:perform_later).and_return(false)
    allow(Rails.logger).to receive(:error)

    expect(JSON.parse(described_class.new(client: client).call(submission))["problems"].first["student_answer"]).to eq("5x")
    expect(Rails.logger).to have_received(:error).with(/reason=enqueue_rejected/)
    expect(submission.answer_file).to be_attached
  end
  it "schedules nothing when upload fails before returning an ID" do
    submission.answer_file.attach(io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      filename: "answer.pdf", content_type: "application/pdf")
    allow(files).to receive(:create).and_raise(Timeout::Error)
    expect(AiFileCleanupJob).not_to receive(:schedule)
    expect(responses).not_to receive(:create)

    expect { described_class.new(client: client).call(submission) }.to raise_error(Timeout::Error)
    expect(submission.answer_file).to be_attached
  end
end
