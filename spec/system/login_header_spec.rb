require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"
require_relative "../support/wordmark_checks"

RSpec.describe "Login header colors", type: :system do
  include WordmarkChecks

  let(:school) { School.create!(school_code: "LOGINBACKGROUND") }
  let(:teacher) { Teacher.create!(school: school, user_id: "background-teacher", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }

  before do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  %w[teacher student admin].each do |role|
    it "matches the #{role} login header to the page background before and after invalid input across widths" do
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
        page.execute_script("window.scrollTo(0, 0)")
        save_brand_evidence("#{role}-login-error-#{width}")
      end
    end
  end

  %w[teacher student].each do |role|
    it "preserves #{role} branding focus and logout on the already signed-in login page" do
      if role == "teacher"
        visit login_path
        fill_in "ユーザーID", with: teacher.user_id
        fill_in "パスワード", with: "password123"
        path, destination = login_path, assignments_path
      else
        student
        visit student_login_path
        fill_in "学校コード", with: school.school_code
        select "1年", from: "学年"
        select "1組", from: "クラス番号"
        select "1番", from: "出席番号"
        fill_in "パスワード", with: "password123"
        path, destination = student_login_path, student_assignments_path
      end
      click_button "ログイン"
      expect(page).to have_current_path(destination)

      [ [ 320, 812 ], [ 375, 812 ], [ 768, 1024 ], [ 1280, 900 ] ].each do |width, height|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
          width: width, height: height, deviceScaleFactor: 1, mobile: false)
        visit path
        expect(page).to have_content("ログイン中")
        expect_login_header
        brand = find_link("QuickFlow", href: destination)
        save_brand_evidence("#{role}-already-signed-in-login-#{width}")
        find("body").send_keys(:tab)
        expect(brand.evaluate_script("document.activeElement === this")).to be(true)
        expect(brand.evaluate_script("[getComputedStyle(this).outlineStyle,getComputedStyle(this).outlineColor]"))
          .to eq([ "solid", "rgb(37, 99, 235)" ])
        expect(brand.evaluate_script("getComputedStyle(this).color")).to eq("rgb(37, 99, 235)")
        save_brand_evidence("#{role}-already-signed-in-login-focused-#{width}")
      end
      click_button "ログアウト"
      expect(page).to have_current_path(path)
      expect_login_header
      visit destination
      expect(page).to have_current_path(path)
    end
  end

  def expect_login_header
    expect(page).to have_css("header.app-header--auth .app-brand", text: "QuickFlow")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('header')).backgroundColor"))
      .to eq("rgb(248, 250, 252)")
    expect(page.evaluate_script("getComputedStyle(document.body).backgroundColor"))
      .to eq("rgb(248, 250, 252)")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.page-card')).backgroundColor"))
      .to eq("rgb(255, 255, 255)")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('header .app-brand')).color"))
      .to eq("rgb(37, 99, 235)")
    expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
    expect_nanum_square_round_wordmark
  end
end
