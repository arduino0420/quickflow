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

    expect(JSON.parse(reader.call(submission))["problems"].first["student_answer"]).to eq("5x")
    expect(files).to have_received(:create).once
    expect(responses).to have_received(:create).once do |request|
      expect(request[:model]).to eq("reading-model")
      instructions = request[:input].first[:content].last[:text]
      expect(instructions).to include("補正・推測しない", "未記入と判読困難を区別", "訂正や候補が不明", "unavailable", "問題を解かず")
    end
  end
end
