require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"
require_relative "../support/crud_browser"

RSpec.describe "Assignment CRUD in Chrome", type: :system do
  include CrudBrowser
  include ActiveJob::TestHelper

  before do
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    @school = School.create!(school_code: "CRUDQUIZ")
    @teacher = Teacher.create!(school: @school, user_id: "crud-teacher", password: "password123")
    @rooms = [ 1, 2, 3 ].map { |n| Classroom.create!(school: @school, teachers: [ @teacher ], grade: 1, class_number: n) }
    @students = @rooms.map { |room| Student.create!(classroom: room, attendance_number: 1, password: "password123") }
    teacher_login(@teacher)
  end

  it "distributes a PDF to multiple classes and scopes lists and details to the recipient and owner" do
    assignment = distribute(title: "複数クラス配信", classrooms: @rooms.first(2))
    expect(assignment.classrooms).to match_array(@rooms.first(2))
    expect(assignment.material_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/pdf_preview_single.pdf")))
    expect(QuestionGenerationJob).to have_been_enqueued.with(assignment, assignment.material_file.blob.id, 0, request_id: assignment.current_question_generation_request_id).once
    click_link "配信済み小テスト"
    click_link assignment.title
    expect(page).to have_css(".distributed-classrooms li", count: 2)
    @students.first(2).each { |student| expect(page).to have_css("#grade_student_#{student.id}") }
    expect(page).not_to have_css("#grade_student_#{@students.last.id}")
    select "1年1組", from: "表示するクラス"
    expect(page).to have_css("#grade_student_#{@students.first.id}")
    expect(page).not_to have_css("#grade_student_#{@students.second.id}")

    student_login(@students.last)
    expect(page).not_to have_content(assignment.title)
    visit student_assignment_path(assignment)
    expect(page).not_to have_css("input[type='file']")
    expect(page).not_to have_content(assignment.title)
    colleague = Teacher.create!(school: @school, user_id: "crud-colleague", password: "password123")
    teacher_login(colleague)
    expect(page).not_to have_content(assignment.title)
    visit assignment_path(assignment)
    expect(page).not_to have_content(assignment.title)
    expect(page).not_to have_button("この小テストを削除する")
  end

  it "cancels or rejects renaming, changes only the title, and deletes only the confirmed quiz graph" do
    assignment = distribute(title: "削除対象", classrooms: @rooms.first(2))
    other = distribute(title: "保持する小テスト", classrooms: [ @rooms.last ])
    # Existing dependent records set up deletion/update preconditions; their C is
    # proved via actual jobs and browser submission in quiz_grading_workflow_spec.
    question = assignment.questions.create!(question_label: "1", position: 1, question_text: "1+1", correct_answer: "2",
      answer_generation_model: "fixture", answer_generation_prompt_version: "v1", answer_generated_at: Time.current)
    submission = Submission.create!(assignment: assignment, student: @students.first, submitted_at: Time.current, status: :completed)
    submission.answer_file.attach(io: StringIO.new(assignment.material_file.download), filename: "answer.pdf", content_type: "application/pdf")
    result = submission.grading_results.create!(question: question, ai_judgment: :incorrect, teacher_judgment: :correct,
      ai_model_name: "fixture", prompt_version: "v1", graded_at: Time.current)
    draft = AnswerDraft.create!(assignment: assignment, student: @students.first,
      material_fingerprint: AnswerDraftContext.fingerprint(assignment), page_data: [ { "page_number" => 1, "operations" => [] } ])
    records = [ *assignment.assignment_classrooms, assignment.current_question_generation_request, question, submission, result, draft ]
    snapshot = records.map { |record| record.reload.attributes }
    expect(submission.reload.score).to eq(5)
    other_pdf = other.material_file.download
    unchanged = assignment.attributes.except("title", "updated_at")
    attachments = ActiveStorage::Attachment.where(record: [ assignment, submission ]).pluck(:id, :blob_id)
    survivors = [ @school, @teacher, *@rooms, *@students, other, other.current_question_generation_request ].map { |record| [ record, record.reload.attributes ] }

    visit assignment_path(assignment)
    click_link "名前を編集"
    fill_in "小テスト名", with: "キャンセル対象"
    click_link "キャンセル"
    expect(page).to have_content("削除対象")
    expect(assignment.reload.title).to eq("削除対象")
    click_link "名前を編集"
    fill_in "小テスト名", with: "   "
    click_button "保存"
    expect(page).to have_css("#assignment-name-errors")
    expect(assignment.reload.title).to eq("削除対象")
    fill_in "小テスト名", with: "変更済み小テスト"
    click_button "保存"
    expect(page).to have_content("小テスト名を変更しました。")
    expect(assignment.reload.title).to eq("変更済み小テスト")
    expect(assignment.attributes.except("title", "updated_at")).to eq(unchanged)
    expect(records.map { |record| record.reload.attributes }).to eq(snapshot)
    expect(submission.reload.score).to eq(5)
    expect(ActiveStorage::Attachment.where(record: [ assignment, submission ]).pluck(:id, :blob_id)).to eq(attachments)

    dismiss_confirm { click_button "この小テストを削除する" }
    expect(page).to have_content("変更済み小テスト")
    expect(assignment.reload).to be_persisted
    expect(records.map { |record| record.reload.attributes }).to eq(snapshot)
    accept_confirm { click_button "この小テストを削除する" }
    expect(page).to have_content("小テスト・提出答案・採点結果・成績を削除しました。")
    expect(Assignment.exists?(assignment.id)).to be(false)
    records.each { |record| expect(record.class.exists?(record.id)).to be(false) }
    expect(ActiveStorage::Attachment.where(id: attachments.map(&:first))).to be_empty
    # Physical deletion belongs to asynchronous ActiveStorage::PurgeJob, not this UI assertion.
    expect(ActiveStorage::PurgeJob).to have_been_enqueued.exactly(2).times
    survivors.each { |record, attributes| expect(record.reload.attributes).to eq(attributes) }
    expect(page).to have_content(other.title)
    expect(other.material_file.download).to eq(other_pdf)
  end
end
