require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "Assignment deletion", type: :request do
  include_context "AI grading records"

  def login(owner = teacher)
    post login_path, params: { session: { user_id: owner.user_id, password: "password123" } }
  end

  def distribute
    assignment.assignment_classrooms.create!(classroom: classroom)
  end

  def document
    Nokogiri::HTML(response.body)
  end

  it "shows a DELETE confirmation including the title, consequences and irreversible deletion, and GET does not delete" do
    distribute
    login
    expect { get assignment_path(assignment) }.not_to change(Assignment, :count)
    form = document.at_css(".assignment-delete-actions form")
    expect(form[:method]).to eq("post")
    expect(form[:action]).to eq(assignment_path(assignment))
    expect(form.at_css("input[name='_method']")[:value]).to eq("delete")
    expect(form["data-turbo-confirm"]).to include(assignment.title, "提出答案・採点結果・成績も削除され、元に戻せません")
    expect(document.at_css(".page-card").element_children.last[:class]).to eq("assignment-delete-actions")
    expect(form.at_css("button").text).to eq("この小テストを削除する")
  end

  [ :unpublished, :distributed, :submitted, :grading, :completed, :needs_review, :failed ].each do |state|
    it "deletes #{state} assignments and their own dependent data only" do
      assignment
      distribute unless state == :unpublished
      if [ :submitted, :grading, :completed, :needs_review, :failed ].include?(state)
        submission.update!(status: state == :needs_review ? :completed : state)
        submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nanswer"), filename: "answer.pdf", content_type: "application/pdf")
        question = create_question
        submission.grading_results.create!(question: question, ai_judgment: :needs_review,
          teacher_judgment: state == :needs_review ? nil : :correct, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
      end
      other = Assignment.create!(teacher: teacher, title: "保持対象", point_per_question: 5)
      other.assignment_classrooms.create!(classroom: classroom)
      other_question = create_question(owner: other)
      other_submission = Submission.create!(assignment: other, student: student, submitted_at: Time.current, status: :completed)
      other_submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nkeep"), filename: "keep.pdf", content_type: "application/pdf")
      other_result = other_submission.grading_results.create!(question: other_question, ai_judgment: :correct,
        ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
      kept = [ school, teacher, classroom, student, other, other_question, other_submission, other_result ]
      original = kept.map { |record| record.reload.attributes }
      login
      get assignment_path(assignment)
      expect(response).to have_http_status(:ok)
      delete assignment_path(assignment)
      expect(response).to redirect_to(assignments_path)
      expect(Assignment.exists?(assignment.id)).to be(false)
      expect(Submission.where(assignment_id: assignment.id)).to be_empty
      expect(Question.where(assignment_id: assignment.id)).to be_empty
      expect(AssignmentClassroom.where(assignment_id: assignment.id)).to be_empty
      expect(kept.map { |record| record.reload.attributes }).to eq(original)
      expect(other_submission.reload.score).to eq(5)
      expect(other_submission.answer_file.download).to eq("%PDF-1.4\nkeep")
      follow_redirect!
      expect(document.at_css("[role='status']").text).to include("PDFファイルはバックグラウンドで削除します")
    end
  end

  [ :anonymous, :student, :other_teacher, :foreign_teacher ].each do |actor|
    it "rejects #{actor} deletion without touching records" do
      distribute
      case actor
      when :student
        post student_login_path, params: { student_session: { school_code: school.school_code, grade: classroom.grade,
          class_number: classroom.class_number, attendance_number: student.attendance_number, password: "password123" } }
      when :other_teacher, :foreign_teacher
        target_school = actor == :foreign_teacher ? School.create!(school_code: "FOREIGN") : school
        login(Teacher.create!(school: target_school, user_id: "other", password: "password123"))
      end
      original = assignment.reload.attributes
      delete assignment_path(assignment)
      if [ :anonymous, :student ].include?(actor)
        expect(response).to redirect_to(login_path)
      else
        expect(response).to have_http_status(:not_found)
      end
      expect(assignment.reload.attributes).to eq(original)
      expect(assignment.material_file).to be_attached
    end
  end

  it "refuses deletion when its distribution is in another school" do
    foreign = School.create!(school_code: "FOREIGN")
    assignment.assignment_classrooms.create!(classroom: Classroom.create!(school: foreign, teacher: teacher, grade: 1, class_number: 1))
    login
    delete assignment_path(assignment)
    expect(response).to redirect_to(assignments_path)
    expect(assignment.reload).to be_persisted
    follow_redirect!
    expect(document.at_css("[role='alert']").text).to include("データは変更していません")
  end

  it "returns an error message with all DB records and files intact after a deletion failure" do
    distribute
    original = assignment.reload.attributes
    allow_any_instance_of(Assignment).to receive(:destroy!).and_raise(ActiveRecord::RecordNotDestroyed)
    login
    delete assignment_path(assignment)
    expect(response).to redirect_to(assignments_path)
    expect(assignment.reload.attributes).to eq(original)
    expect(assignment.assignment_classrooms.count).to eq(1)
    expect(assignment.material_file).to be_attached
    follow_redirect!
    expect(document.at_css("[role='alert']").text).to include("データは変更していません")
  end

  it "protects deletion with CSRF verification" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    distribute
    get login_path
    token = document.at_css("input[name='authenticity_token']")[:value]
    post login_path, params: { authenticity_token: token, session: { user_id: teacher.user_id, password: "password123" } }
    get assignment_path(assignment)
    form = document.at_css(".assignment-delete-actions form")
    token = form.at_css("input[name='authenticity_token']")[:value]
    delete form[:action]
    expect(response).to have_http_status(:unprocessable_content)
    expect(Assignment.exists?(assignment.id)).to be(true)
    delete form[:action], params: { authenticity_token: token }
    expect(response).to redirect_to(assignments_path)
    expect(Assignment.exists?(assignment.id)).to be(false)
  ensure
    ActionController::Base.allow_forgery_protection = original
  end
end
