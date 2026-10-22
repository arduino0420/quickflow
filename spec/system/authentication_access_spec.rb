require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"

RSpec.describe "Authentication and access boundaries in Chrome", type: :system do
  let(:school) { School.create!(school_code: "AUTHSYS") }
  let(:teacher) { Teacher.create!(school: school, user_id: "auth-teacher", password: "password123") }
  let(:room) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: room, attendance_number: 1, password: "58392047") }
  let(:admin) { Admin.create!(school: school, user_id: "auth-admin", password: "password123") }
  let(:other_school) { School.create!(school_code: "AUTHOTHER") }
  let(:outsider) { Teacher.create!(school: other_school, user_id: "other-school-teacher", password: "password123") }
  let(:other_room) { Classroom.create!(school: other_school, teachers: [ outsider ], grade: 1, class_number: 1) }
  let(:colleague) { Teacher.create!(school: school, user_id: "same-class-teacher", password: "password123") }
  let(:unassigned_room) { Classroom.create!(school: school, teachers: [ colleague ], grade: 1, class_number: 2) }
  let(:assignment) { distribute(teacher, room, "本人の小テスト") }

  before do
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    student
    admin
  end

  it "rejects a teacher's wrong password without granting a teacher session" do
    login_teacher(password: "incorrect")
    expect(page).to have_css('[role="alert"]', text: "ユーザーIDまたはパスワードが正しくありません。")
    visit assignments_path
    expect(page).to have_current_path(login_path)
    expect(page).to have_css("h1", text: "教師ログイン")
  end

  it "rejects an admin's wrong password without granting admin access" do
    login_admin(password: "incorrect")
    expect(page).to have_css('[role="alert"]', text: "管理者IDまたはパスワードが正しくありません。")
    visit admin_teachers_path
    expect(page).to have_current_path(admin_login_path)
    expect(page).to have_css("h1", text: "管理者ログイン")
  end

  it "requires the student's password and complete school/grade/class/number combination" do
    [ { password: "incorrect" }, { school_code: other_school.school_code },
      { grade: "2年" }, { class_number: "2組" }, { attendance_number: "2番" } ].each do |change|
      login_student(**change)
      expect(page).to have_css('[role="alert"]', text: "ログイン情報またはパスワードが正しくありません。")
      visit student_assignments_path
      expect(page).to have_current_path(student_login_path)
      expect(page).to have_css("h1", text: "生徒ログイン")
    end
    login_student
    expect(page).to have_current_path(student_assignments_path)
  end

  it "does not restore a student's private assignment list after logout and Back" do
    assignment
    original = snapshot
    login_student
    expect(page).to have_link(assignment.title)
    click_button "ログアウト"
    expect(page).to have_current_path(student_login_path)
    page.go_back
    expect(page).to have_css("h1", text: "生徒ログイン")
    expect(page).to have_no_link(assignment.title)
    visit student_assignment_path(assignment)
    expect(page).to have_current_path(student_login_path)
    expect(snapshot).to eq(original)
  end

  it "does not restore an admin's private account list after logout and Back" do
    teacher
    original = snapshot
    login_admin
    click_link "教師一覧"
    expect(page).to have_content(teacher.user_id)
    click_button "ログアウト"
    expect(page).to have_current_path(admin_login_path)
    page.go_back
    expect(page).to have_css("h1", text: "管理者ログイン")
    expect(page).to have_no_content(teacher.user_id)
    visit admin_teachers_path
    expect(page).to have_current_path(admin_login_path)
    expect(snapshot).to eq(original)
  end

  it "replaces the old role on teacher/student and admin/general-user switches" do
    original = snapshot
    login_teacher
    expect(page).to have_current_path(assignments_path)
    login_student
    expect(page).to have_current_path(student_assignments_path)
    visit assignments_path
    expect(page).to have_current_path(login_path)
    login_admin
    expect(page).to have_current_path(admin_root_path)
    visit student_assignments_path
    expect(page).to have_current_path(student_login_path)
    login_teacher
    expect(page).to have_current_path(assignments_path)
    visit admin_teachers_path
    expect(page).to have_current_path(admin_login_path)
    login_admin
    expect(page).to have_current_path(admin_root_path)
    login_student
    expect(page).to have_current_path(student_assignments_path)
    visit admin_students_path
    expect(page).to have_current_path(admin_login_path)
    expect(snapshot).to eq(original)
  end

  it "redirects unauthenticated direct URLs to each role's login" do
    assignment
    original = snapshot
    { assignments_path => login_path, assignment_path(assignment) => login_path,
      new_student_path => login_path, student_assignment_path(assignment) => student_login_path,
      admin_teachers_path => admin_login_path, admin_students_path => admin_login_path }.each do |path, destination|
      visit path
      expect(page).to have_current_path(destination)
      expect(page).to have_button("ログイン")
    end
    expect(snapshot).to eq(original)
  end

  [ :teacher, :student ].each do |role|
    it "hides admin links/forms from #{role} and rejects direct admin reads and writes" do
      assignment
      original = snapshot
      role == :teacher ? login_teacher : login_student
      expect(page).to have_current_path(role == :teacher ? assignments_path : student_assignments_path)
      expect(page).to have_no_css('a[href^="/admin"], form[action^="/admin"]', visible: :all)
      # Replay a real page form through Chrome with an adversarial admin target.
      result = browser_form_request('form', admin_teacher_path(teacher), method: "PATCH",
        fields: { "teacher[password]" => "Changed12345", "teacher[password_confirmation]" => "Changed12345" })
      expect(result).to eq("status" => 200, "path" => admin_login_path)
      [ admin_root_path, admin_teachers_path, admin_students_path ].each do |path|
        visit path
        expect(page).to have_current_path(admin_login_path)
        expect(page).to have_css("h1", text: "管理者ログイン")
      end
      visit(role == :teacher ? assignments_path : student_assignments_path)
      expect(page).to have_css("h1", text: role == :teacher ? "配信済み小テスト" : "配信された小テスト")
      expect(snapshot).to eq(original)
    end
  end

  it "denies another assigned teacher the creator's quiz, answers, editing and grading" do
    room.teachers << colleague
    protected_assignment = distribute(colleague, room, "別教師の非公開情報")
    protected_result = graded_answer(protected_assignment)
    answer = protected_result.submission
    own_result = graded_answer(assignment)
    original = snapshot
    login_teacher
    expect(page).to have_no_link(protected_assignment.title)
    [ assignment_path(protected_assignment), edit_assignment_path(protected_assignment),
      assignment_submission_path(protected_assignment, answer), answer_assignment_submission_path(protected_assignment, answer) ].each do |path|
      expect_browser_not_found(path)
    end
    visit edit_assignment_path(assignment)
    expect(page).to have_css("h1", text: "小テスト名を編集")
    expect(browser_form_request("form", assignment_path(protected_assignment), method: "PATCH",
      fields: { "assignment[title]" => "越権変更" })).to include("status" => 404)
    expect(browser_form_request("form", assignment_path(protected_assignment), method: "DELETE")).to include("status" => 404)
    visit assignment_submission_path(assignment, own_result.submission)
    expect(page).to have_css("h1", text: "答案詳細")
    expect(browser_form_request("#teacher-judgments", assignment_submission_path(protected_assignment, answer), method: "PATCH",
      fields: { "final_judgments[#{protected_result.id}]" => "incorrect",
        "original_final_judgments[#{protected_result.id}]" => "correct" })).to include("status" => 404)
    expect(snapshot).to eq(original)
  end

  it "denies a teacher another school's quiz and its modification" do
    foreign_assignment = distribute(outsider, other_room, "他校の非公開情報")
    assignment
    original = snapshot
    login_teacher
    expect(page).to have_no_link(foreign_assignment.title)
    expect_browser_not_found(assignment_path(foreign_assignment))
    visit edit_assignment_path(assignment)
    expect(page).to have_css("h1", text: "小テスト名を編集")
    expect(browser_form_request("form", assignment_path(foreign_assignment), method: "PATCH",
      fields: { "assignment[title]" => "越権変更" })).to include("status" => 404)
    expect(snapshot).to eq(original)
  end

  it "restricts teacher student registration to assigned classes, preserving the teacher session" do
    unassigned_room
    other_room
    original = snapshot
    login_teacher
    visit new_student_path
    expect(page).to have_select("担当クラス", options: [ "選択してください", "1年1組" ])
    [ unassigned_room, other_room ].each do |target|
      expect(browser_form_request('form[action="/students"]', students_path, method: "POST",
        fields: { "student[classroom_id]" => target.id.to_s, "student[attendance_number]" => "2",
          "student[password]" => "73580926", "student[password_confirmation]" => "73580926" })).to include("status" => 404)
      expect(snapshot).to eq(original)
    end
    select "1年1組", from: "担当クラス"
    fill_in "出席番号", with: "2"
    fill_in "初期パスワード", with: "73580926", exact: true
    fill_in "初期パスワード（確認）", with: "73580926"
    expect { click_button "登録"; expect(page).to have_content("生徒アカウントを登録しました。") }.to change(Student, :count).by(1)
    visit assignments_path
    expect(page).to have_current_path(assignments_path)
    expect(page).to have_content(teacher.user_id)
    visit student_assignments_path
    expect(page).to have_current_path(student_login_path)
  end

  it "denies student reads and submissions for undistributed, other-class and other-school quizzes" do
    hidden = Assignment.create!(teacher: teacher, title: "未配信", point_per_question: 5)
    other_class = distribute(teacher, unassigned_room, "別クラス限定")
    foreign_assignment = distribute(outsider, other_room, "他校限定")
    assignment
    original = snapshot
    login_student
    expect(page).to have_link(assignment.title)
    [ hidden, other_class, foreign_assignment ].each do |target|
      expect(page).to have_no_link(target.title)
      expect_browser_not_found(student_assignment_path(target))
    end
    visit student_assignment_path(assignment)
    expect(page).to have_css("h1", exact_text: assignment.title)
    find("summary", text: "従来のPDFアップロード").click
    attach_file "解答PDF", Rails.root.join("spec/fixtures/files/material.pdf")
    [ hidden, other_class, foreign_assignment ].each do |target|
      expect(browser_form_request("form", student_assignment_submission_path(target), method: "POST")).to include("status" => 404)
      expect(snapshot).to eq(original)
    end
  end

  it "restricts admin account listing, editing and writes to the admin's school" do
    foreign_student = Student.create!(classroom: other_room, attendance_number: 1, password: "58392047")
    teacher
    original = snapshot
    login_admin
    click_link "教師一覧"
    expect(page).to have_content(teacher.user_id)
    expect(page).to have_no_content(outsider.user_id)
    [ edit_admin_teacher_path(outsider), edit_admin_student_path(foreign_student) ].each { |path| expect_browser_not_found(path) }
    visit edit_admin_teacher_path(teacher)
    expect(page).to have_css("h1", text: "教師アカウントの編集")
    expect(browser_form_request('form[action="' + admin_teacher_path(teacher) + '"]', admin_teacher_path(outsider), method: "PATCH",
      fields: { "teacher[password]" => "Changed12345", "teacher[password_confirmation]" => "Changed12345",
        "confirmed" => "1", "admin_password" => "password123" })).to include("status" => 404)
    visit edit_admin_student_path(student)
    expect(page).to have_css("h1", text: "生徒")
    expect(browser_form_request('form[action="' + confirm_update_admin_student_path(student) + '"]', confirm_update_admin_student_path(foreign_student),
      method: "POST", fields: { "student[attendance_number]" => "2" })).to include("status" => 404)
    [ "PATCH", "DELETE" ].each do |method|
      expect(browser_form_request('form[action="' + confirm_update_admin_student_path(student) + '"]', admin_student_path(foreign_student),
        method: method, fields: { "confirmed" => "1", "admin_password" => "password123" })).to include("status" => 404)
    end
    expect(snapshot).to eq(original)
  end

  def login_teacher(password: "password123")
    visit login_path
    fill_in "ユーザーID", with: teacher.user_id
    fill_in "パスワード", with: password
    click_button "ログイン"
    expect(page).to have_current_path(assignments_path) if password == "password123"
  end

  def login_admin(password: "password123")
    visit admin_login_path
    fill_in "管理者ID", with: admin.user_id
    fill_in "パスワード", with: password
    click_button "ログイン"
    expect(page).to have_current_path(admin_root_path) if password == "password123"
  end

  def login_student(password: "58392047", school_code: school.school_code, grade: "1年", class_number: "1組", attendance_number: "1番")
    visit student_login_path
    fill_in "学校コード", with: school_code
    select grade, from: "学年"
    select class_number, from: "クラス番号"
    select attendance_number, from: "出席番号"
    fill_in "パスワード", with: password
    click_button "ログイン"
    if [ password, school_code, grade, class_number, attendance_number ] == [ "58392047", school.school_code, "1年", "1組", "1番" ]
      expect(page).to have_current_path(student_assignments_path)
    else
      expect(page).to have_css('[role="alert"]', text: "ログイン情報またはパスワードが正しくありません。")
    end
  end

  def distribute(owner, classroom, title)
    item = Assignment.create!(teacher: owner, title: title, point_per_question: 5)
    item.assignment_classrooms.create!(classroom: classroom)
    item
  end

  def graded_answer(item)
    answer = Submission.create!(assignment: item, student: student, submitted_at: Time.current, status: :completed)
    answer.answer_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")),
      filename: "answer.pdf", content_type: "application/pdf")
    question = item.questions.create!(position: 1, question_label: "1", question_text: "1+1", correct_answer: "2",
      answer_generation_model: "stub", answer_generation_prompt_version: "v1", answer_generated_at: Time.current)
    answer.grading_results.create!(question: question, ai_judgment: :correct, student_answer: "2",
      ai_model_name: "stub", prompt_version: "v1", graded_at: Time.current)
  end

  # Do not include rate-limit bookkeeping: login attempts intentionally update it.
  def snapshot
    [ School, Teacher, Admin, Classroom, TeacherClassroom, Student, Assignment, AssignmentClassroom,
      Question, Submission, GradingResult, AnswerDraft, ActiveStorage::Blob, ActiveStorage::Attachment ].to_h do |model|
      [ model.name, model.order(:id).map(&:attributes) ]
    end
  end

  def expect_browser_not_found(path)
    visit path
    # Verify the actual HTTP response in Chrome, without depending on debug/error-page titles.
    expect(page.evaluate_async_script(<<~JS, path)).to eq(404)
      const done = arguments[arguments.length - 1];
      fetch(arguments[0], {credentials: 'same-origin'}).then(r => done(r.status));
    JS
  end

  # Serialize an existing application form, then tamper only its target/fields.
  # This is an actual Chrome request with the browser session and CSRF token.
  def browser_form_request(selector, path, method:, fields: {})
    expect(page).to have_css(selector, visible: :all)
    page.evaluate_async_script(<<~JS, selector, path, method, fields)
      const [selector, path, method, fields, done] = arguments;
      const data = new FormData(document.querySelector(selector));
      data.delete('_method');
      for (const [name, value] of Object.entries(fields)) data.set(name, value);
      fetch(path, {method, body: data, credentials: 'same-origin',
        headers: {'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || ''}})
        .then(r => done({status: r.status, path: new URL(r.url).pathname}));
    JS
  end
end
