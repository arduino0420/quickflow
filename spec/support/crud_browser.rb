# Shared only by the CRUD browser audit; all records and uploads are synthetic.
module CrudBrowser
  def teacher_login(teacher)
    visit login_path
    fill_in "ユーザーID", with: teacher.user_id
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(assignments_path)
  end

  def admin_login(admin)
    visit admin_login_path
    fill_in "管理者ID", with: admin.user_id
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(admin_root_path)
  end

  def student_login(student)
    visit student_login_path
    fill_in "学校コード", with: student.classroom.school.school_code
    select "#{student.classroom.grade}年", from: "学年"
    select "#{student.classroom.class_number}組", from: "クラス番号"
    select "#{student.attendance_number}番", from: "出席番号"
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(student_assignments_path)
  end

  def distribute(title:, classrooms:)
    visit new_assignment_path
    fill_in "タイトル", with: title
    fill_in "1問あたりの点数", with: 5
    attach_file "教材ファイル（必須）", Rails.root.join("spec/fixtures/files/pdf_preview_single.pdf")
    classrooms.each { |room| check "classroom_#{room.id}" }
    click_button "配信"
    expect(page).to have_content("小テストを配信しました")
    Assignment.find_by!(title: title)
  end

  def draw_answer
    click_button "ペン"
    canvas = find('[data-pdf-preview-target="ink"]')
    canvas.scroll_to(:center)
    rect = canvas.evaluate_script("this.getBoundingClientRect().toJSON()")
    x = (rect["x"] + rect["width"] * 0.2).round
    y = (rect["y"] + rect["height"] * 0.2).round
    page.driver.browser.action.move_to_location(x, y).pointer_down(:left)
      .move_to_location(x + 30, y + 10).pointer_up(:left).perform
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 15)
  end
end
