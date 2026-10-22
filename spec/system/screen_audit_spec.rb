require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"
require_relative "../support/ai_grading_context"

RSpec.describe "Screen audit", type: :system do
  include_context "AI grading records"

  before do
    FileUtils.mkdir_p(Rails.root.join("tmp", "issue95"))
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    @admin = Admin.create!(school: school, user_id: "audit-admin", password: "password123")
  end

  def audit(name, title: nil)
    expect(page).to have_css("h1", count: 1)
    expect(page).to have_title(title || "#{page.find('h1').text} | QuickFlow", exact: true)
    [ 320, 390, 768, 1280 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: false)
      expect(page.evaluate_script("innerWidth")).to eq(width)
      expect(page.evaluate_script("document.documentElement.scrollWidth")).to be <= width
      if page.has_css?(".review-table-container", wait: 0)
        table = page.evaluate_script(<<~JS)
          (() => { const e = document.querySelector('.review-table-container');
            e.scrollLeft = e.scrollWidth;
            return { overflow: getComputedStyle(e).overflowX, scroll: e.scrollLeft, excess: e.scrollWidth - e.clientWidth }; })()
        JS
        expect(table["overflow"]).to eq("auto")
        expect(table["scroll"]).to be > 0 if table["excess"].positive?
        page.execute_script("document.querySelector('.review-table-container').scrollLeft = 0")
      end
      bounds = page.evaluate_script(<<~JS)
        [...document.querySelectorAll('main input:not([type="hidden"]), main select, main button, main textarea')]
          .filter(e => e.getClientRects().length && !e.closest('.review-table-container'))
          .map(e => { const r = e.getBoundingClientRect(); return [r.left, r.right, r.width, r.height]; })
      JS
      bounds.each do |left, right, element_width, height|
        expect(left).to be >= 0
        expect(right).to be <= width
        expect(element_width).to be > 0
        expect(height).to be > 0
      end
      screenshot = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true, fromSurface: true,
        clip: { x: 0, y: 0, width: width, height: page.evaluate_script("document.documentElement.scrollHeight"), scale: 1 })
      Rails.root.join("tmp", "issue95", "#{name}-#{width}.png").binwrite(Base64.decode64(screenshot.fetch("data")))
    end
  end

  def teacher_login
    visit login_path
    fill_in "ユーザーID", with: teacher.user_id
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(assignments_path)
  end

  it "audits public forms and teacher pages, including long grading content and return navigation" do
    visit root_path
    audit("home", title: "QuickFlow | 小テストの学習支援")
    [ [ login_path, "teacher-login" ], [ student_login_path, "student-login" ], [ new_student_path, "student-registration" ] ].each do |path, name|
      visit path
      audit(name)
    end
    teacher_login
    audit("teacher-empty")
    submission.update!(status: :completed)
    submission.grading_results.create!(question: create_question(text: "長い問題文" * 60), ai_judgment: :needs_review,
      feedback: "長いフィードバック" * 40, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    visit new_assignment_path
    audit("assignment-new")
    visit edit_assignment_path(assignment)
    audit("assignment-edit")
    visit assignments_path
    audit("teacher-list")
    visit assignment_path(assignment, classroom_id: "all", filter: "needs_review")
    audit("grades-review")
    find(".grade-row-link", match: :first).click
    audit("submission-long")
    select "正解", from: "問題1(1)の最終判定"
    click_button "保存"
    expect(page).to have_content("判定を保存しました。")
    click_link "小テスト詳細へ戻る"
    expect(page).to have_current_path(assignment_path(assignment, classroom_id: "all", filter: "needs_review"))
    audit("grades-empty-review")
    visit assignments_path
    click_button "ログアウト"
    expect(page).to have_current_path(login_path)
  end

  it "audits every admin form and confirmation, including the empty teacher state" do
    visit admin_login_path
    audit("admin-login")
    fill_in "管理者ID", with: @admin.user_id
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(admin_root_path)
    audit("admin-dashboard")
    visit admin_teachers_path
    expect(page).to have_content("登録されている教師はいません。")
    audit("admin-teachers-empty")
    classroom
    student
    [ [ admin_teachers_path, "admin-teachers" ], [ new_admin_teacher_path, "admin-teacher-new" ],
      [ edit_admin_teacher_path(teacher), "admin-teacher-edit" ], [ admin_students_path, "admin-students" ],
      [ new_admin_student_path, "admin-student-new" ], [ edit_admin_student_path(student), "admin-student-edit" ],
      [ edit_admin_student_password_reset_path(student), "admin-password" ],
      [ confirm_destroy_admin_student_path(student), "admin-delete-confirm" ] ].each do |path, name|
      visit path
      audit(name)
    end
    visit edit_admin_student_path(student)
    select "2番", from: "出席番号"
    click_button "変更内容を確認する"
    audit("admin-update-confirm")
  end

  it "audits student detail before and after grading, preserving the PDF screen contract" do
    submission.update!(status: :completed)
    submission.grading_results.create!(question: create_question, ai_judgment: :correct,
      ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    visit student_login_path
    fill_in "学校コード", with: school.school_code
    select "1年", from: "学年"
    select "1組", from: "クラス番号"
    select "1番", from: "出席番号"
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(student_assignments_path)
    audit("student-list")
    visit student_assignment_path(assignment)
    audit("student-graded", title: "小テスト詳細・採点結果 | QuickFlow")
    fresh = Assignment.create!(teacher: teacher, title: "未提出の小テスト" * 12, point_per_question: 5)
    fresh.assignment_classrooms.create!(classroom: classroom)
    fresh.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")), filename: "material.pdf", content_type: "application/pdf")
    visit student_assignment_path(fresh)
    audit("student-unsubmitted", title: "小テスト詳細・採点結果 | QuickFlow")
    visit student_assignment_pdf_preview_path(fresh)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    audit("student-pdf", title: "小テストの解答 | QuickFlow")
    expect(page).to have_no_link("小テスト詳細へ戻る")
    expect(page).to have_no_css("footer")
  end
end
