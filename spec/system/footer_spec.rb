require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"

RSpec.describe "Footer layout", type: :system do
  before do
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    @school = School.create!(school_code: "FOOTERSYS")
    @teacher = Teacher.create!(school: @school, user_id: "footer-system", password: "password123")
    classroom = Classroom.create!(school: @school, teachers: [ @teacher ], grade: 1, class_number: 1)
    Student.create!(classroom: classroom, attendance_number: 1, password: "password123")
    Admin.create!(school: @school, user_id: "footer-admin", password: "password123")
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "keeps the footer below content and at the viewport bottom on home and each login page" do
    [ [ 320, 568 ], [ 390, 844 ], [ 768, 1024 ], [ 1280, 900 ], [ 1280, 480 ], [ 390, 1200 ] ].each do |width, height|
      resize_viewport(width, height)
      [ root_path, login_path, student_login_path, admin_login_path ].each do |path|
        visit path
        assert_footer_layout
      end
    end
    visit root_path
    page.find("body").send_keys(:tab)
    expect(page.evaluate_script("document.activeElement.textContent")).to eq("教師としてログインする")
    page.driver.browser.switch_to.active_element.send_keys(:enter)
    expect(page).to have_current_path(login_path)
  end

  it "follows long teacher content, student content and admin tables without covering their controls" do
    18.times do |i|
      assignment = Assignment.create!(teacher: @teacher, title: "小テスト #{i + 1}", point_per_question: 5)
      assignment.assignment_classrooms.create!(classroom: @school.classrooms.sole)
    end
    visit login_path
    fill_in "ユーザーID", with: @teacher.user_id
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(assignments_path)
    assert_responsive_footer(long: true)

    visit student_login_path
    select "1年", from: "学年"
    select "1組", from: "クラス番号"
    select "1番", from: "出席番号"
    fill_in "学校コード", with: @school.school_code
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(student_assignments_path)
    assert_responsive_footer(long: true)

    visit admin_login_path
    fill_in "管理者ID", with: "footer-admin"
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(admin_root_path)
    digest = @teacher.password_digest
    Teacher.insert_all!(18.times.map { |i| { school_id: @school.id, user_id: "footer-table-#{i}", password_digest: digest } })
    visit admin_teachers_path
    expect(page).to have_css(".admin-teacher-list tbody tr", count: 19)
    assert_responsive_footer(long: true)
    find(".admin-teacher-row-actions a", match: :first).click
    expect(page).to have_content("教師アカウントの編集")
  end

  def resize_viewport(width, height)
    page.current_window.resize_to(width, height)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
      width: width, height: height, deviceScaleFactor: 1, mobile: false)
    expect(page.evaluate_script("[innerWidth, innerHeight]")).to eq([ width, height ])
  end

  def assert_responsive_footer(long: false)
    [ [ 320, 568 ], [ 390, 844 ], [ 768, 1024 ], [ 1280, 900 ] ].each do |width, height|
      resize_viewport(width, height)
      page.execute_script("window.scrollTo(0, 0)")
      assert_footer_layout
      expect(page.evaluate_script("document.querySelector('footer').getBoundingClientRect().top >= innerHeight")).to be(true) if long
      page.execute_script("window.scrollTo(0, document.documentElement.scrollHeight)")
      expect(page.evaluate_script("document.querySelector('footer').getBoundingClientRect().bottom <= innerHeight + 1")).to be(true)
    end
  end

  def assert_footer_layout
    expect(page).to have_css("body > main + footer", exact_text: "© QuickFlow")
    expect(page).to have_no_css("footer a, footer button, footer [tabindex]")
    geometry = page.evaluate_script(<<~JS)
      (() => {
        const footer = document.querySelector('footer'), main = document.querySelector('main');
        const f = footer.getBoundingClientRect(), m = main.getBoundingClientRect();
        const header = document.querySelector('body > header');
        return {
          follows: f.top >= m.bottom - 1,
          bottom: Math.abs(f.bottom + scrollY - document.documentElement.scrollHeight) <= 1,
          fills: f.bottom + scrollY >= innerHeight - 1,
          fits: document.documentElement.scrollWidth <= innerWidth,
          headerTop: header ? header.getBoundingClientRect().top + scrollY : 0,
          position: getComputedStyle(footer).position
        };
      })()
    JS
    expect(geometry).to eq("follows" => true, "bottom" => true, "fills" => true, "fits" => true,
      "headerTop" => 0, "position" => "static")
  end
end
