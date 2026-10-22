require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"

RSpec.describe "Japanese error layout", type: :system do
  before do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 900 ]
    school = School.create!(school_code: "ERRORLAYOUT")
    teacher = Teacher.create!(school: school, user_id: "error-layout-teacher", password: "teacher-password")
    Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1)
    Admin.create!(school: school, user_id: "error-layout-admin", password: "admin-password")
  end

  def check_phone_layout(name)
    [ 320, 390 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: true)
      expect(page).to have_css('[role="alert"] li', minimum: 2)
      layout = page.evaluate_script(<<~JS)
        (() => {
          const alert = document.querySelector('[role="alert"]');
          const form = document.querySelector('main form');
          const elements = [alert, ...form.querySelectorAll('input:not([type="hidden"]), button, select')];
          return {
            viewport: innerWidth, pageWidth: document.documentElement.scrollWidth,
            alertBottom: alert.getBoundingClientRect().bottom, formTop: form.getBoundingClientRect().top,
            bounds: elements.map(element => {
              const rect = element.getBoundingClientRect();
              return [rect.left, rect.right, rect.width, rect.height];
            })
          };
        })()
      JS
      expect(layout["viewport"]).to eq(width)
      expect(layout["pageWidth"]).to be <= layout["viewport"]
      expect(layout["alertBottom"]).to be <= layout["formTop"]
      layout["bounds"].each do |left, right, element_width, height|
        expect(left).to be >= 0
        expect(right).to be <= layout["viewport"]
        expect(element_width).to be > 0
        expect(height).to be > 0
      end
      expect(page).to have_button
      screenshot = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, fromSurface: true,
        clip: { x: 0, y: 0, width: width, height: page.evaluate_script("document.documentElement.scrollHeight"), scale: 1 })
      Rails.root.join("tmp", "issue94-#{name}-#{width}.png").binwrite(Base64.decode64(screenshot.fetch("data")))
    end
  end

  it "keeps multiple assignment errors and all controls visible on narrow screens" do
    visit login_path
    fill_in "ユーザーID", with: "error-layout-teacher"
    fill_in "パスワード", with: "teacher-password"
    click_button "ログイン"
    expect(page).to have_current_path(assignments_path)
    visit new_assignment_path
    fill_in "1問あたりの点数", with: "0"
    page.execute_script("document.querySelector('main form').noValidate = true")
    click_button "配信"
    expect(page).to have_content("小テスト名を入力してください")
    expect(page).to have_content("1問あたりの点数は1以上で入力してください")
    expect(page).to have_content("教材PDFを選択してください")
    check_phone_layout("assignment")
  end

  it "wraps long account errors without hiding password fields or the registration button" do
    visit admin_login_path
    fill_in "管理者ID", with: "error-layout-admin"
    fill_in "パスワード", with: "admin-password"
    click_button "ログイン"
    expect(page).to have_current_path(admin_root_path)
    visit new_admin_teacher_path
    fill_in "パスワード", with: "A1" * 50, exact: true
    fill_in "パスワード（確認）", with: "different"
    page.execute_script("document.querySelector('main form').noValidate = true")
    click_button "教師を登録する"
    expect(page).to have_content("ユーザーIDを入力してください")
    expect(page).to have_content("パスワード（確認）がパスワードと一致しません")
    check_phone_layout("account")
  end
end
