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

  it "saves the answer reading result to the submission" do
    result = <<~TEXT
      問題番号：1(1)
      生徒の最終解答：4/6
      読み取り状態：読める
      読み取り理由：解答欄から読み取れる。
    TEXT

    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    allow(reader).to receive(:call).with(submission).and_return(result)

    described_class.perform_now(submission)

    expect(submission.reload.extracted_text).to eq(result)
  end
end
