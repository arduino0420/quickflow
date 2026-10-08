RSpec.shared_context "AI grading records" do
  let(:school) { School.create!(school_code: "AI#{SecureRandom.hex(4)}") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher-#{SecureRandom.hex(4)}", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  let(:assignment) do
    item = Assignment.create!(teacher: teacher, title: "式の計算", point_per_question: 5)
    item.material_file.attach(io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      filename: "material.pdf", content_type: "application/pdf")
    item
  end
  let(:problem) do
    { question_label: "1(1)", question_text: "3x+2x を計算しなさい。", student_answer: "5x",
      reading_status: "readable", reading_reason: "明確に読める" }
  end
  let(:submission) do
    Submission.create!(assignment: assignment, student: student, submitted_at: Time.current,
      extracted_text: JSON.generate(problems: [ problem ]))
  end
  let(:files) { instance_double(OpenAI::Resources::Files) }
  let(:responses) { instance_double(OpenAI::Resources::Responses) }
  let(:client) { instance_double(OpenAI::Client, files: files, responses: responses) }

  def ai_response(data = nil, model: "test-model", **attributes)
    data ||= attributes
    instance_double(OpenAI::Models::Responses::Response, output_text: JSON.generate(data), model: model,
      status: "completed", output: [], id: nil, incomplete_details: nil, error: nil, usage: nil)
  end

  def create_question(position: 1, label: "1(1)", text: problem[:question_text], answer: "5x", requires_work: false, owner: assignment)
    Question.create!(assignment: owner, question_label: label, position: position,
      question_text: text, correct_answer: answer,
      grading_rule: JSON.generate(criteria: "同類項をまとめる。", requires_work: requires_work),
      answer_generation_model: "test-generator", answer_generation_prompt_version: "v1", answer_generated_at: Time.current)
  end

  def judgment(question, value: "correct", **details)
    { question_id: question.id, ai_judgment: value, error_point: nil, feedback: nil, review_reason: nil, **details }
  end
end
