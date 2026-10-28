require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"
require_relative "../support/wordmark_checks"

RSpec.describe "Login header colors", type: :system do
  include WordmarkChecks

  before do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  %w[teacher student admin].each do |role|
    it "keeps the #{role} login header white and blue before and after invalid input across widths" do
      path = { "teacher" => login_path, "student" => student_login_path, "admin" => admin_login_path }.fetch(role)
      [ [ 320, 812 ], [ 375, 812 ], [ 768, 1024 ], [ 1280, 900 ] ].each do |width, height|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
          width: width, height: height, deviceScaleFactor: 1, mobile: false)
        visit path
        expect_login_header
        save_brand_evidence("#{role}-login-#{width}")

        case role
        when "teacher"
          fill_in "ユーザーID", with: "missing-teacher-#{width}"
        when "student"
          fill_in "学校コード", with: "MISSING#{width}"
          select "1年", from: "学年"
          select "1組", from: "クラス番号"
          select "1番", from: "出席番号"
        else
          fill_in "管理者ID", with: "missing-admin-#{width}"
        end
        fill_in "パスワード", with: "incorrect-password"
        click_button "ログイン"
        expect(page).to have_current_path(path)
        expect(page).to have_css("[role='alert']", text: "正しくありません。")
        expect_login_header
        expect(find("input[type='password']").value).to be_empty
        save_brand_evidence("#{role}-login-error-#{width}")
      end
    end
  end

  def expect_login_header
    expect(page).to have_css("header.app-header--auth .app-brand", text: "QuickFlow")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('header')).backgroundColor"))
      .to eq("rgb(255, 255, 255)")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('header .app-brand')).color"))
      .to eq("rgb(37, 99, 235)")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
    expect_nunito_wordmark
  end
end
