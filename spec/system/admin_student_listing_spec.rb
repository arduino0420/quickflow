require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"

RSpec.describe "Admin student listing", type: :system do
  before do
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    school = School.create!(school_code: "BROWSERLIST")
    Admin.create!(school: school, user_id: "browser-admin", password: "admin-password")
    digest = BCrypt::Password.create("student-password")
    [ [ 1, 1, 40 ], [ 1, 2, 1 ], [ 2, 1, 1 ] ].each do |grade, number, count|
      room = Classroom.create!(school: school, grade: grade, class_number: number)
      Student.insert_all!((1..count).map { |attendance| { classroom_id: room.id, attendance_number: attendance, password_digest: digest } })
    end
    visit admin_login_path
    fill_in "管理者ID", with: "browser-admin"
    fill_in "パスワード", with: "admin-password"
    click_button "ログイン"
    click_link "生徒一覧"
  end

  it "filters and paginates while retaining conditions, and links to the existing screens" do
    expect(page).to have_css("[data-student-id]", count: 40)
    select "1年", from: "学年"
    click_button "絞り込む"
    expect(page).to have_content("全41件")
    click_link "次のページ"
    expect(page).to have_select("学年", selected: "1年")
    expect(page).to have_css("[data-student-id]", count: 1)
    expect(page).to have_content("2組")
    select "1組", from: "クラス"
    click_button "絞り込む"
    expect(page).to have_content("全40件（1 / 1ページ）")
    click_link "生徒を新規登録"
    expect(page).to have_content("生徒の新規登録")
    visit admin_root_path
    expect(page).to have_link("教師一覧", href: admin_teachers_path)
    expect(page).to have_link("生徒を新規登録", href: new_admin_student_path)
  end

  it "keeps student details readable on a narrow screen" do
    page.current_window.resize_to(390, 844)
    expect(page).to have_css("[data-student-id]", count: 40)
    expect(page).to have_content("利用可能")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
    click_link "管理者トップへ戻る"
    expect(page).to have_content("管理者トップ")
  end
end
