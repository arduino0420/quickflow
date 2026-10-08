
require "rails_helper"

RSpec.describe AnswerReadingJob, type: :job do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "student-password") }
  let(:assignment) { Assignment.create!(teacher: teacher, title: "式の計算", point_per_question: 5) }

  let(:submission) do
    Submission.create!(
      student: student,
      assignment: assignment,
      status: :submitted,
      submitted_at: Time.current
    )
  end

  let(:valid_result) do
    {
      problems: [
        {
          question_label: "1(1)",
          question_text: "3x + 2x を計算しなさい。",
          student_answer: "5x",
          reading_status: "readable",
          reading_reason: "最終解答を明確に読み取れる"
        }
      ]
    }.to_json
  end

  it "saves valid JSON reading results to the submission" do
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    allow(reader).to receive(:call).with(submission).and_return(valid_result)

    described_class.perform_now(submission)

    data = JSON.parse(submission.reload.extracted_text)

    expect(data["problems"].first["question_label"]).to eq("1(1)")
    expect(data["problems"].first["question_text"]).to eq("3x + 2x を計算しなさい。")
    expect(data["problems"].first["student_answer"]).to eq("5x")
    expect(data["problems"].first["reading_status"]).to eq("readable")
    expect(submission).to be_grading
  end

  it "marks the submission as failed when JSON is invalid" do
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    allow(reader).to receive(:call).with(submission).and_return("invalid JSON")

    described_class.perform_now(submission)

    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to be_nil
  end

  it "marks the submission as failed when the AI raises an error" do
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    allow(reader).to receive(:call).with(submission).and_raise(StandardError, "API error")

    described_class.perform_now(submission)

    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to be_nil
  end

  it "marks the submission as failed when required fields are missing" do
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    allow(reader).to receive(:call).with(submission).and_return(
      { problems: [ { question_label: "1(1)" } ] }.to_json
    )

    described_class.perform_now(submission)

    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to be_nil
  end
end
