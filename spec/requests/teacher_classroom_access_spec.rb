require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "Many-to-many classroom access", type: :request do
  include_context "AI grading records"

  let(:colleague) { Teacher.create!(school: school, user_id: "colleague", password: "password123") }

  def login_as(actor)
    post "/login", params: { session: { user_id: actor.user_id, password: "password123" } }
    expect(response).to have_http_status(:see_other)
  end

  def register_student(number)
    post students_path, params: { student: { classroom_id: classroom.id.to_s, attendance_number: number.to_s,
      password: "password123", password_confirmation: "password123" } }
  end

  it "allows both assigned teachers to register students in the same classroom" do
    classroom.teachers << colleague
    [ teacher, colleague ].each_with_index do |actor, index|
      login_as(actor)
      get new_student_path
      expect(Nokogiri::HTML(response.body).css("option").map { |option| option[:value] }).to include(classroom.id.to_s)
      expect { register_student(index + 1) }.to change(Student, :count).by(1)
      expect(response).to have_http_status(:see_other)
    end
  end

  it "does not grant student registration using only the obsolete teacher_id" do
    classroom.teachers.delete(teacher)
    classroom.update_columns(teacher_id: teacher.id)
    login_as(teacher)

    expect { register_student(1) }.not_to change(Student, :count)
    expect(response).to have_http_status(:not_found)
    expect(teacher.reload.classrooms).to be_empty
  end

  it "preserves classroom data, PDFs and grading when one or all relationships are removed" do
    submission.update!(status: :completed)
    submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nanswer"), filename: "answer.pdf", content_type: "application/pdf")
    result = submission.grading_results.create!(question: create_question, ai_judgment: :needs_review,
      teacher_judgment: :correct, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    classroom.teachers << colleague
    protected_records = [ classroom, student, assignment, assignment.assignment_classrooms.sole, submission, result.question, result,
      assignment.material_file_attachment, assignment.material_file.blob, submission.answer_file_attachment, submission.answer_file.blob ]
    original = protected_records.map { |record| record.reload.attributes }
    pdf = submission.answer_file.download

    teacher.classrooms.delete(classroom)
    expect(classroom.reload.teachers).to contain_exactly(colleague)
    login_as(teacher)
    register_student(2)
    expect(response).to have_http_status(:not_found)
    # Quiz ownership and grading access do not depend on classroom membership.
    get assignment_submission_path(assignment, submission)
    expect(response).to have_http_status(:ok)
    get export_assignment_path(assignment, classroom_id: "all")
    expect(response).to have_http_status(:ok)

    classroom.teachers.clear
    expect(classroom.reload.teachers).to be_empty
    expect(protected_records.map { |record| record.reload.attributes }).to eq(original)
    expect(submission.answer_file.download).to eq(pdf)
  end

  it "does not grant another assigned teacher access to the creator's quiz, results, PDF or export" do
    submission.update!(status: :completed)
    result = submission.grading_results.create!(question: create_question, ai_judgment: :needs_review,
      teacher_judgment: :correct, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    classroom.teachers << colleague
    login_as(colleague)
    original = result.attributes

    [ assignment_path(assignment), edit_assignment_path(assignment), assignment_submission_path(assignment, submission),
      answer_assignment_submission_path(assignment, submission), export_assignment_path(assignment, classroom_id: "all") ].each do |path|
      get path
      expect(response).to have_http_status(:not_found)
    end
    patch assignment_submission_path(assignment, submission), params: { judgments: { result.id.to_s => "incorrect" }, original_final_judgments: { result.id.to_s => result.reload.final_judgment } }
    expect(response).to have_http_status(:not_found)
    expect(result.reload.attributes).to eq(original)
  end
end
