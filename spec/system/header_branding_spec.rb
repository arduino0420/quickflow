require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"
require_relative "../support/wordmark_checks"

RSpec.describe "Shared header wordmarks", type: :system do
  include WordmarkChecks

  let(:school) { School.create!(school_code: "ROUNDEDBRAND") }
  let(:teacher) { Teacher.create!(school: school, user_id: "branding-teacher-#{'long' * 10}", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 3, class_number: 10) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 40, password: "password123") }
  let(:admin) { Admin.create!(school: school, user_id: "branding-admin", password: "password123") }

  before do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    page.driver.browser.execute_cdp("Network.enable")
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [ "*://fonts.googleapis.com/*", "*://fonts.gstatic.com/*" ])
  end

  after do
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  %w[teacher student admin].each do |role|
    it "preserves #{role} identity, logo navigation, logout styling and DELETE behavior across widths" do
      destination, logout, identity = case role
      when "teacher"
        visit login_path
        fill_in "ユーザーID", with: teacher.user_id
        fill_in "パスワード", with: "password123"
        [ assignments_path, login_path, teacher.user_id ]
      when "student"
        student
        visit student_login_path
        fill_in "学校コード", with: school.school_code
        select "3年", from: "学年"
        select "10組", from: "クラス番号"
        select "40番", from: "出席番号"
        fill_in "パスワード", with: "password123"
        [ student_assignments_path, student_login_path, "3年10組40番" ]
      else
        visit admin_login_path
        fill_in "管理者ID", with: admin.user_id
        fill_in "パスワード", with: "password123"
        [ admin_root_path, admin_login_path, nil ]
      end
      click_button "ログイン"
      expect(page).to have_current_path(destination)
      expect(page).to have_link("QuickFlow", href: destination)
      expect(page).to have_css("header", text: identity) if identity
      expect(page).not_to have_css("header", text: admin.user_id) if role == "admin"

      [ [ 320, 812 ], [ 375, 812 ], [ 768, 1024 ], [ 1280, 900 ] ].each do |width, height|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: false)
        expect_nunito_wordmark
        expect(page.evaluate_script("getComputedStyle(document.querySelector('header')).backgroundColor")).to eq("rgb(37, 99, 235)")
        brand = find("header .app-brand")
        expect(brand.evaluate_script("getComputedStyle(this).color")).to eq("rgb(255, 255, 255)")
        brand.hover
        expect(brand.evaluate_script("getComputedStyle(this).color")).to eq("rgb(255, 255, 255)")
        if identity
          expect(find(".#{role}-header-identity").evaluate_script("getComputedStyle(this).color")).to eq("rgb(255, 255, 255)")
        end
        button = find("header button", text: "ログアウト")
        style = button.evaluate_script("(() => { const s=getComputedStyle(this); return [s.backgroundColor,s.color,s.borderRadius,s.fontWeight,s.fontFamily]; })()")
        expect(style[0..3]).to eq(role == "admin" ? [ "rgb(37, 99, 235)", "rgb(255, 255, 255)", "8px", "600" ] : [ "rgb(255, 255, 255)", "rgb(37, 99, 235)", "8px", "600" ])
        expect(style.last).not_to include("Nunito")
        expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
        expect(page.evaluate_script(<<~JS)).to be(true)
          (() => {
            const b=document.querySelector('header .app-brand').getBoundingClientRect();
            const a=document.querySelector('.app-header-actions').getBoundingClientRect();
            return (b.right <= a.left || b.bottom <= a.top) && a.right <= innerWidth && a.left >= 0;
          })()
        JS
        if role == "admin"
          expect(page.evaluate_script(<<~JS)).to be <= 1
            (() => {
              const b=document.querySelector('header .app-brand').getBoundingClientRect();
              const a=document.querySelector('.app-header-actions').getBoundingClientRect();
              return Math.abs((b.top+b.bottom)/2 - (a.top+a.bottom)/2);
            })()
          JS
        end
        find("header .app-brand").send_keys(:tab)
        expect(page.evaluate_script("document.activeElement.textContent")).to eq("ログアウト")
        expect(page.evaluate_script("getComputedStyle(document.querySelector('.app-header-actions')).outlineColor")).to eq("rgb(255, 255, 255)")
        save_brand_evidence("#{role}-header-#{width}")
      end
      button = find("header button", text: "ログアウト")
      form = button.find(:xpath, "..")
      expect(form["method"]).to eq("post")
      expect(form.find('input[name="_method"]', visible: false)["value"]).to eq("delete")
      button.click
      expect(page).to have_current_path(logout)
      visit destination
      expect(page).to have_current_path(logout)
    end
  end

  it "loads the same local font in standalone error wordmarks without external font services" do
    %w[/400.html /404.html /406-unsupported-browser.html /422.html /500.html].each do |path|
      visit path
      expect_nunito_wordmark
      expect(page).to have_link("トップページへ", href: "/")
      [ 320, 375, 768, 1280 ].each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: false)
        expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
        save_brand_evidence("#{path.delete_prefix('/')}-#{width}")
      end
    end
  end
end
