require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"
require_relative "../support/crud_browser"

RSpec.describe "Account CRUD in Chrome", type: :system do
  include CrudBrowser

  before do
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    @school = School.create!(school_code: "CRUDACCOUNTS")
    @admin = Admin.create!(school: @school, user_id: "crud-admin", password: "password123")
    @room = Classroom.create!(school: @school, grade: 1, class_number: 1)
    admin_login(@admin)
  end

  def confirm_change
    fill_in "管理者自身のパスワード", with: "password123"
    check "表示された対象と操作内容を確認しました"
    click_button "この生徒の変更を確定する"
    expect(page).to have_content("生徒アカウントを更新しました。")
  end

  it "registers a teacher, reuses and creates classrooms, and creates/deletes responsibility links without deleting learning records" do
    click_link "教師を新規登録"
    expect(page).to have_field("学校コード", with: @school.school_code, readonly: true)
    fill_in "教師ID", with: "new-crud-teacher"
    fill_in "パスワード", with: "Teacher83920", exact: true
    fill_in "パスワード（確認）", with: "Teacher83920"
    check "teacher_classroom_1_1"
    check "teacher_classroom_1_2"
    click_button "教師を登録する"
    expect(page).to have_content("教師アカウントを登録しました。")
    teacher = Teacher.find_by!(user_id: "new-crud-teacher")
    new_room = @school.classrooms.find_by!(grade: 1, class_number: 2)
    expect(teacher.classrooms).to match_array([ @room, new_room ])
    expect(@school.classrooms.where(grade: 1, class_number: 1).count).to eq(1)
    original = teacher.attributes.except("updated_at")
    student = Student.create!(classroom: @room, attendance_number: 1, password: "password123")
    assignment = Assignment.create!(teacher: teacher, title: "担当解除後も保持", point_per_question: 5)
    assignment.assignment_classrooms.create!(classroom: @room)
    submission = Submission.create!(assignment: assignment, student: student, submitted_at: Time.current)
    survivors = [ @room, new_room, student, assignment, submission ].map { |record| [ record, record.attributes ] }
    retained_link = teacher.teacher_classrooms.find_by!(classroom: @room)
    removed_link = teacher.teacher_classrooms.find_by!(classroom: new_room)
    visit admin_teachers_path
    expect(page).to have_content("所属学校コード: CRUDACCOUNTS")
    find("a[href='#{edit_admin_teacher_path(teacher)}']").click
    uncheck "teacher_classroom_1_2"
    check "teacher_classroom_1_3"
    click_button "変更を保存する"
    expect(page).to have_content("教師アカウントを更新しました。")
    third_room = @school.classrooms.find_by!(grade: 1, class_number: 3)
    expect(teacher.classrooms.reload).to match_array([ @room, third_room ])
    expect(retained_link.reload).to be_persisted
    expect(TeacherClassroom.exists?(removed_link.id)).to be(false)
    expect(teacher.teacher_classrooms.find_by!(classroom: third_room).id).not_to eq(removed_link.id)
    find("a[href='#{edit_admin_teacher_path(teacher)}']").click
    uncheck "teacher_classroom_1_1"
    uncheck "teacher_classroom_1_3"
    click_button "変更を保存する"
    expect(page).to have_content("担当なし")
    expect(teacher.teacher_classrooms.reload).to be_empty
    expect(teacher.reload.attributes.except("updated_at")).to eq(original)
    expect(teacher.authenticate("Teacher83920")).to be_truthy
    survivors.each { |record, attributes| expect(record.reload.attributes).to eq(attributes) }
  end

  it "registers an admin-managed student, safely corrects unused membership, and registers a teacher-managed student" do
    click_link "生徒を新規登録"
    expect(page).to have_field("学校コード", with: @school.school_code, readonly: true)
    select "1年", from: "学年"
    select "1組", from: "クラス"
    select "1番", from: "出席番号"
    fill_in "パスワード", with: "58392047", exact: true
    fill_in "パスワード（確認）", with: "58392047"
    click_button "生徒を登録する"
    expect(page).to have_content("生徒アカウントを登録しました。")
    student = @room.students.sole
    original = student.attributes.except("classroom_id", "updated_at")
    visit edit_admin_student_path(student)
    select "2組", from: "クラス"
    click_button "変更内容を確認する"
    expect(page).to have_content("変更後: 1年 2組 1番")
    expect(student.reload.classroom).to eq(@room)
    confirm_change
    expect(student.reload.classroom).to eq(@school.classrooms.find_by!(grade: 1, class_number: 2))
    expect(student.attributes.except("classroom_id", "updated_at")).to eq(original)
    expect(student.authenticate("58392047")).to be_truthy
    expect(@room.reload).to be_persisted

    teacher = Teacher.create!(school: @school, user_id: "register-crud", password: "password123")
    TeacherClassroom.create!(teacher: teacher, classroom: @room)
    teacher_login(teacher)
    visit new_student_path
    select "1年1組", from: "担当クラス"
    fill_in "出席番号", with: 2
    fill_in "初期パスワード", with: "72618490", exact: true
    fill_in "初期パスワード（確認）", with: "72618490"
    click_button "登録", exact: true
    expect(page).to have_content("登録しました")
    registered = @room.students.find_by!(attendance_number: 2)
    expect(registered.authenticate("72618490")).to be_truthy
    visit assignments_path
    expect(page).to have_current_path(assignments_path)
  end

  [ :draft, :submission, :source_distribution, :destination_distribution ].each do |restriction|
    it "retains learning data and rejects membership movement for #{restriction}" do
      teacher = Teacher.create!(school: @school, user_id: "history-crud", password: "password123")
      destination = Classroom.create!(school: @school, grade: 1, class_number: 2)
      student = Student.create!(classroom: @room, attendance_number: 1, password: "password123")
      assignment = Assignment.create!(teacher: teacher, title: "保持する履歴", point_per_question: 5)
      case restriction
      when :draft
        AnswerDraft.create!(student: student, assignment: assignment, material_fingerprint: "a" * 64,
          page_data: [ { "page_number" => 1, "operations" => [] } ])
      when :submission
        assignment.assignment_classrooms.create!(classroom: @room)
        Submission.create!(student: student, assignment: assignment, submitted_at: Time.current)
      when :source_distribution
        assignment.assignment_classrooms.create!(classroom: @room)
      when :destination_distribution
        assignment.assignment_classrooms.create!(classroom: destination)
      end
      records = [ student, assignment, *assignment.assignment_classrooms, *assignment.answer_drafts, *assignment.submissions ]
      snapshot = records.map(&:attributes)
      visit edit_admin_student_path(student)
      select "2組", from: "クラス"
      click_button "変更内容を確認する"
      # This non-Turbo form replaces the document. Wait for its response before
      # reading nodes; the original edit page already contains the warning text.
      expect(page).to have_current_path(confirm_update_admin_student_path(student))
      expect(page).to have_css('[role="alert"]', text: "所属を変更できません。")
      expect(page).not_to have_button("この生徒の変更を確定する")
      expect(records.map { |record| record.reload.attributes }).to eq(snapshot)

      unless restriction == :destination_distribution
        visit confirm_destroy_admin_student_path(student)
        fill_in "管理者自身のパスワード", with: "password123"
        check "表示された対象と操作内容を確認しました"
        click_button "この生徒1人を削除する"
        expect(page).to have_content("提出・下書き・配信課題がある生徒は削除できません。")
        expect(records.map { |record| record.reload.attributes }).to eq(snapshot)
      end
      # History blocks moving, but correcting the number within the same class is allowed.
      visit edit_admin_student_path(student)
      select "3番", from: "出席番号"
      click_button "変更内容を確認する"
      confirm_change
      expect(student.reload.attendance_number).to eq(3)
      expect(student.classroom).to eq(@room)
      records.drop(1).zip(snapshot.drop(1)).each { |record, attributes| expect(record.reload.attributes).to eq(attributes) }
    end
  end
end
