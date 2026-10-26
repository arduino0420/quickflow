require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"

RSpec.describe "Admin account management", type: :system do
  before do
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    @school = School.create!(school_code: "BROWSERACCOUNTS")
    Admin.create!(school: @school, user_id: "browser-accounts", password: "admin-secret")
    @room = Classroom.create!(school: @school, grade: 1, class_number: 1)
    @first = Student.create!(classroom: @room, attendance_number: 1, password: "original-secret")
    @second = Student.create!(classroom: @room, attendance_number: 2, password: "second-secret")
    visit admin_login_path
    fill_in "管理者ID", with: "browser-accounts"
    fill_in "パスワード", with: "admin-secret"
    click_button "ログイン"
    expect(page).to have_current_path(admin_root_path)
    expect(page).to have_title("管理者トップ | QuickFlow", exact: true)
  end

  def choose_operation(student, label)
    within("[data-student-id='#{student.id}']") { click_link label }
  end

  it "shows four ordered dashboard links in one row at desktop and tablet widths, and wraps on narrow screens" do
    expected = [ "教師を新規登録", "生徒を新規登録", "教師一覧", "生徒一覧" ]
    expect(page.all(".admin-dashboard-action").map(&:text)).to eq(expected)
    [ 1280, 768 ].each do |width|
      page.current_window.resize_to(width, 900)
      positions = page.evaluate_script("Array.from(document.querySelectorAll('.admin-dashboard-action')).map(e => e.getBoundingClientRect().top)")
      expect(positions.uniq.size).to eq(1)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    end
    page.current_window.resize_to(390, 844)
    positions = page.evaluate_script("Array.from(document.querySelectorAll('.admin-dashboard-action')).map(e => e.getBoundingClientRect().top)")
    expect(positions.uniq.size).to eq(4)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    click_link "教師を新規登録"
    expect(page).to have_content("教師の新規登録")
  end

  it "resets consecutive students manually, retaining list filters and reusing the fixed reauthentication window" do
    click_link "生徒一覧"
    select "1年", from: "学年"
    select "1組", from: "クラス"
    click_button "絞り込む"
    choose_operation(@first, "パスワード再設定")
    expect(page).to have_content("1年 1組 1番")
    fill_in "新しいパスワード", with: "58392047", exact: true
    fill_in "新しいパスワード（確認）", with: "58392047"
    fill_in "管理者自身のパスワード", with: "admin-secret"
    check "表示された対象と操作内容を確認しました"
    click_button "この生徒のパスワードを保存する"
    expect(page).to have_content("生徒ID #{@first.id} のパスワードを再設定しました。")
    expect(page).to have_select("学年", selected: "1年")
    expect(page).to have_select("クラス", selected: "1組")
    choose_operation(@second, "パスワード再設定")
    expect(page).to have_content("1年 1組 2番")
    expect(page).not_to have_field("管理者自身のパスワード")
    fill_in "新しいパスワード", with: "72618490", exact: true
    fill_in "新しいパスワード（確認）", with: "72618490"
    check "表示された対象と操作内容を確認しました"
    click_button "この生徒のパスワードを保存する"
    expect(page).to have_content("生徒ID #{@second.id} のパスワードを再設定しました。")
    expect(@first.reload.authenticate("58392047")).to be_truthy
    expect(@second.reload.authenticate("72618490")).to be_truthy
  end

  it "confirms an attendance correction before committing, then deletes only an explicitly confirmed unused account" do
    click_link "生徒一覧"
    choose_operation(@first, "編集")
    select "3番", from: "出席番号"
    click_button "変更内容を確認する"
    expect(page).to have_current_path(confirm_update_admin_student_path(@first), ignore_query: true)
    expect(page).to have_title("生徒の変更内容を確認 | QuickFlow", exact: true)
    expect(page).to have_content("変更後: 1年 1組 3番")
    expect(@first.reload.attendance_number).to eq(1)
    fill_in "管理者自身のパスワード", with: "admin-secret"
    check "表示された対象と操作内容を確認しました"
    click_button "この生徒の変更を確定する"
    expect(page).to have_content("生徒アカウントを更新しました。")
    expect(@first.reload.attendance_number).to eq(3)
    choose_operation(@second, "削除")
    expect(page).to have_content("1年 1組 2番")
    expect(page).to have_content("元に戻せません")
    click_link "削除せず生徒一覧へ戻る"
    expect(page).to have_current_path(admin_students_path, ignore_query: true)
    expect(page).to have_title("生徒一覧 | QuickFlow", exact: true)
    expect(@second.reload).to be_persisted
    choose_operation(@second, "削除")
    fill_in "管理者自身のパスワード", with: "admin-secret"
    check "表示された対象と操作内容を確認しました"
    click_button "この生徒1人を削除する"
    expect(page).to have_content("確認した生徒1人を削除しました。")
    expect(page).not_to have_css("[data-student-id='#{@second.id}']")
    expect(@first.reload).to be_persisted
  end

  [ 0, 150 ].each do |latency|
    it "revisits deletion confirmation safely with #{latency}ms network latency and sends exactly one DELETE" do
      browser = page.driver.browser
      browser.execute_cdp("Network.enable")
      browser.execute_cdp("Network.emulateNetworkConditions", offline: false, latency: latency,
        downloadThroughput: -1, uploadThroughput: -1)
      requests = []
      observer = lambda do |event|
        data = event.payload
        if data[:controller] == "Admin::StudentsController" && data[:action] == "destroy"
          requests << [ data[:method], data[:path].split("?").first, data[:status] ]
        end
      end
      original = @first.reload.attributes
      ActiveSupport::Notifications.subscribed(observer, "process_action.action_controller") do
        click_link "生徒一覧"
        3.times do
          choose_operation(@second, "削除")
          expect(page).to have_content("1年 1組 2番")
          click_link "削除せず生徒一覧へ戻る"
          expect(@second.reload).to be_persisted
        end
        expect(requests).to be_empty
        choose_operation(@second, "削除")
        fill_in "管理者自身のパスワード", with: "admin-secret"
        check "表示された対象と操作内容を確認しました"
        click_button "この生徒1人を削除する"
        expect(page).to have_content("確認した生徒1人を削除しました。")
        expect(page).not_to have_css("[data-student-id='#{@second.id}']")
      end
      expect(requests).to eq([ [ "DELETE", admin_student_path(@second), 303 ] ])
      expect(Student.exists?(@second.id)).to be(false)
      expect(@first.reload.attributes).to eq(original)
    ensure
      browser&.execute_cdp("Network.emulateNetworkConditions", offline: false, latency: 0,
        downloadThroughput: -1, uploadThroughput: -1)
    end
  end

  it "preserves narrow-screen student listing and the existing teacher password editing flow" do
    teacher = Teacher.create!(school: @school, user_id: "browser-teacher", password: "old-teacher-secret")
    click_link "生徒一覧"
    page.current_window.resize_to(390, 844)
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    choose_operation(@first, "パスワード再設定")
    expect(page).to have_content("生徒のパスワード再設定")
    visit admin_teachers_path
    click_link "パスワード再設定"
    fill_in "新しいパスワード", with: "NewTeacher8392", exact: true
    fill_in "新しいパスワード（確認）", with: "NewTeacher8392"
    fill_in "管理者自身のパスワード（パスワード変更時）", with: "admin-secret"
    check "表示された教師のパスワード変更を確認しました"
    click_button "変更を保存する"
    expect(page).to have_content("教師アカウントを更新しました。")
    expect(teacher.reload.authenticate("NewTeacher8392")).to be_truthy
  end
end
