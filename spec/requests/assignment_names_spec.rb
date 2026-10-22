require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "Assignment name editing", type: :request do
  include_context "AI grading records"

  before do
    assignment.assignment_classrooms.create!(classroom: classroom)
    expect(QuestionGenerationJob).not_to receive(:perform_later)
    expect(AnswerReadingJob).not_to receive(:perform_later)
    expect(AnswerGradingJob).not_to receive(:perform_later)
  end

  def login(owner = teacher)
    post login_path, params: { session: { user_id: owner.user_id, password: "password123" } }
  end

  def document
    Nokogiri::HTML(response.body)
  end

  it "opens a title-only form with the current name and cancels without changes" do
    login
    original = assignment.reload.attributes
    get assignment_path(assignment)
    link = document.at_css("a[href='#{edit_assignment_path(assignment)}']")
    expect(link.text).to eq("名前を編集")
    get link[:href]

    expect(response).to have_http_status(:ok)
    form = document.at_css("form[action='#{assignment_path(assignment)}']")
    expect(form.at_css("input[name='_method']")[:value]).to eq("patch")
    expect(form.css("[name^='assignment[']").map { |field| field[:name] }).to eq([ "assignment[title]" ])
    expect(form.at_css("input[name='assignment[title]']")[:value]).to eq(assignment.title)
    expect(form.at_css("input[type='submit']")[:value]).to eq("保存")
    cancel = form.css("a").find { |item| item.text == "キャンセル" }
    expect(cancel[:href]).to eq(assignment_path(assignment))
    get cancel[:href]
    expect(assignment.reload.attributes).to eq(original)
  end

  it "saves the owner's new name and displays it in the details and list" do
    login
    patch assignment_path(assignment), params: { assignment: { title: "式の計算 第2回" } }

    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(assignment_path(assignment))
    expect(assignment.reload.title).to eq("式の計算 第2回")
    follow_redirect!
    expect(response.body).to include("小テスト名を変更しました。", "式の計算 第2回")
    get assignments_path
    expect(response.body).to include("式の計算 第2回")
  end

  [ "", "   ", "　" ].each do |title|
    it "rejects a blank name #{title.inspect} and shows the attempted value with errors" do
      login
      original = assignment.reload.attributes
      patch assignment_path(assignment), params: { assignment: { title: title } }

      expect(response).to have_http_status(422)
      expect(document.at_css("[role='alert']").text).to include("小テスト名を保存できませんでした", "小テスト名を入力してください")
      expect(document.at_css("input[name='assignment[title]']")[:value]).to eq(title)
      expect(assignment.reload.attributes).to eq(original)
    end
  end

  it "displays validation errors when saving fails for another model validation" do
    login
    allow_any_instance_of(Assignment).to receive(:update) do |item|
      item.errors.add(:base, "保存できませんでした")
      false
    end
    patch assignment_path(assignment), params: { assignment: { title: "新しい名前" } }

    expect(response).to have_http_status(422)
    expect(document.at_css("[role='alert']").text).to include("保存できませんでした")
    expect(assignment.reload.title).to eq("式の計算")
  end

  it "ignores other attributes and preserves PDFs, destinations, answers, grading and scores" do
    question = create_question
    submission.update!(status: :completed)
    submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nanswer"), filename: "answer.pdf", content_type: "application/pdf")
    result = submission.grading_results.create!(question: question, ai_judgment: :incorrect, teacher_judgment: :correct,
      ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
    original_assignment = assignment.reload.attributes.except("title", "updated_at")
    original_links = assignment.assignment_classrooms.map(&:attributes)
    original_question = question.reload.attributes
    original_submission = submission.reload.attributes
    original_result = result.reload.attributes
    original_files = ActiveStorage::Attachment.order(:id).map(&:attributes)
    original_blobs = ActiveStorage::Blob.order(:id).map(&:attributes)
    score = submission.score
    login

    patch assignment_path(assignment), params: { assignment: {
      title: "新しい名前", point_per_question: 100, teacher_id: 999999, published_at: Time.current,
      classroom_ids: [], material_file: fixture_file_upload("material.txt", "text/plain"),
      questions_attributes: [ { id: question.id, correct_answer: "変更" } ],
      submissions_attributes: [ { id: submission.id, status: "failed" } ]
    } }

    expect(response).to redirect_to(assignment_path(assignment))
    expect(assignment.reload.title).to eq("新しい名前")
    expect(assignment.attributes.except("title", "updated_at")).to eq(original_assignment)
    expect(assignment.assignment_classrooms.reload.map(&:attributes)).to eq(original_links)
    expect(question.reload.attributes).to eq(original_question)
    expect(submission.reload.attributes).to eq(original_submission)
    expect(result.reload.attributes).to eq(original_result)
    expect(ActiveStorage::Attachment.order(:id).map(&:attributes)).to eq(original_files)
    expect(ActiveStorage::Blob.order(:id).map(&:attributes)).to eq(original_blobs)
    expect(submission.score).to eq(score)
    expect(score).to eq(5)
  end

  [ :same_school_teacher, :other_school_teacher, :student, :anonymous ].each do |actor|
    it "rejects edit and update by #{actor}" do
      case actor
      when :same_school_teacher, :other_school_teacher
        other_school = actor == :other_school_teacher ? School.create!(school_code: "OTHER") : school
        other_teacher = Teacher.create!(school: other_school, user_id: "other", password: "password123")
        login(other_teacher)
      when :student
        post student_login_path, params: { student_session: {
          school_code: school.school_code, grade: classroom.grade, class_number: classroom.class_number,
          attendance_number: student.attendance_number, password: "password123"
        } }
      end
      original = assignment.reload.attributes

      get edit_assignment_path(assignment)
      expect(response).to have_http_status(actor.to_s.end_with?("teacher") ? :not_found : :see_other)
      expect(response).to redirect_to(login_path) if [ :student, :anonymous ].include?(actor)
      patch assignment_path(assignment), params: { assignment: { title: "不正な変更" } }
      expect(response).to have_http_status(actor.to_s.end_with?("teacher") ? :not_found : :see_other)
      expect(response).to redirect_to(login_path) if [ :student, :anonymous ].include?(actor)
      expect(assignment.reload.attributes).to eq(original)
    end
  end

  it "rejects an owned assignment distributed only to another school" do
    foreign_school = School.create!(school_code: "FOREIGN")
    foreign_teacher = Teacher.create!(school: foreign_school, user_id: "foreign", password: "password123")
    foreign_classroom = Classroom.create!(school: foreign_school, teachers: [ foreign_teacher ], grade: 1, class_number: 1)
    AssignmentClassroom.where(assignment: assignment).delete_all
    assignment.assignment_classrooms.build(classroom: foreign_classroom).tap { |link| link.save!(validate: false) } # Historical foreign distribution.
    login

    get edit_assignment_path(assignment)
    expect(response).to have_http_status(:not_found)
    patch assignment_path(assignment), params: { assignment: { title: "不正な変更" } }
    expect(response).to have_http_status(:not_found)
    expect(assignment.reload.title).to eq("式の計算")
  end

  it "escapes the name in the form and after saving" do
    login
    title = '<script>alert("name")</script>'
    patch assignment_path(assignment), params: { assignment: { title: title } }
    follow_redirect!
    expect(document.at_css(".assignment-title span").text).to eq(title)
    expect(document.at_css(".assignment-title script")).to be_nil
    get edit_assignment_path(assignment)
    expect(document.at_css("input[name='assignment[title]']")[:value]).to eq(title)
  end
end
