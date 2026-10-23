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

  def audit(name, path:, title:)
    # Non-Turbo submissions replace the document. Both old and new pages have
    # an h1, so wait for the destination before querying visible DOM nodes.
    expect(page).to have_current_path(path)
    expect(page).to have_title(title, exact: true)
    expect(page).to have_css("h1", count: 1)
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
    audit("home", path: root_path, title: "QuickFlow | 小テストの学習支援")
    [ [ login_path, "teacher-login", "教師ログイン" ], [ student_login_path, "student-login", "生徒ログイン" ] ].each do |path, name, heading|
      visit path
      audit(name, path: path, title: "#{heading} | QuickFlow")
    end
    teacher_login
    audit("teacher-empty", path: assignments_path, title: "配信済み小テスト | QuickFlow")
    classroom
    visit new_student_path
    expect(page).to have_select("担当クラス", options: [ "選択してください", "1年1組" ])
    audit("student-registration", path: new_student_path, title: "生徒アカウント登録 | QuickFlow")
    submission.update!(status: :completed)
    submission.grading_results.create!(question: create_question(text: "長い問題文" * 60), ai_judgment: :needs_review,
      feedback: "長いフィードバック" * 40, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    visit new_assignment_path
    audit("assignment-new", path: new_assignment_path, title: "小テスト配信 | QuickFlow")
    visit edit_assignment_path(assignment)
    audit("assignment-edit", path: edit_assignment_path(assignment), title: "小テスト名を編集 | QuickFlow")
    visit assignments_path
    audit("teacher-list", path: assignments_path, title: "配信済み小テスト | QuickFlow")
    visit assignment_path(assignment, classroom_id: "all", filter: "needs_review")
    audit("grades-review", path: assignment_path(assignment, classroom_id: "all", filter: "needs_review"), title: "小テスト詳細 | QuickFlow")
    find(".grade-row-link", match: :first).click
    audit("submission-long", path: assignment_submission_path(assignment, submission, classroom_id: "all", filter: "needs_review"), title: "答案詳細 | QuickFlow")
    select "正解", from: "問題1(1)の最終判定"
    click_button "保存"
    expect(page).to have_content("判定を保存しました。")
    click_link "小テスト詳細へ戻る"
    expect(page).to have_current_path(assignment_path(assignment, classroom_id: "all", filter: "needs_review"))
    audit("grades-empty-review", path: assignment_path(assignment, classroom_id: "all", filter: "needs_review"), title: "小テスト詳細 | QuickFlow")
    visit assignments_path
    click_button "ログアウト"
    expect(page).to have_current_path(login_path)
  end

  it "audits every admin form and confirmation, including the empty teacher state" do
    visit admin_login_path
    audit("admin-login", path: admin_login_path, title: "管理者ログイン | QuickFlow")
    fill_in "管理者ID", with: @admin.user_id
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(admin_root_path)
    audit("admin-dashboard", path: admin_root_path, title: "管理者トップ | QuickFlow")
    visit admin_teachers_path
    expect(page).to have_content("登録されている教師はいません。")
    audit("admin-teachers-empty", path: admin_teachers_path, title: "教師一覧 | QuickFlow")
    classroom
    student
    [ [ admin_teachers_path, "admin-teachers", "教師一覧" ], [ new_admin_teacher_path, "admin-teacher-new", "教師の新規登録" ],
      [ edit_admin_teacher_path(teacher), "admin-teacher-edit", "教師アカウントの編集" ], [ admin_students_path, "admin-students", "生徒一覧" ],
      [ new_admin_student_path, "admin-student-new", "生徒の新規登録" ], [ edit_admin_student_path(student), "admin-student-edit", "生徒アカウントの編集" ],
      [ edit_admin_student_password_reset_path(student), "admin-password", "生徒のパスワード再設定" ],
      [ confirm_destroy_admin_student_path(student), "admin-delete-confirm", "生徒アカウントの削除確認" ] ].each do |path, name, heading|
      visit path
      audit(name, path: path, title: "#{heading} | QuickFlow")
    end
    visit edit_admin_student_path(student)
    select "2番", from: "出席番号"
    click_button "変更内容を確認する"
    audit("admin-update-confirm", path: confirm_update_admin_student_path(student), title: "生徒の変更内容を確認 | QuickFlow")
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
    audit("student-list", path: student_assignments_path, title: "配信された小テスト | QuickFlow")
    visit student_assignment_path(assignment)
    audit("student-graded", path: student_assignment_path(assignment), title: "小テスト詳細・採点結果 | QuickFlow")
    fresh = Assignment.create!(teacher: teacher, title: "未提出の小テスト" * 12, point_per_question: 5)
    fresh.assignment_classrooms.create!(classroom: classroom)
    fresh.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")), filename: "material.pdf", content_type: "application/pdf")
    visit student_assignment_path(fresh)
    audit("student-unsubmitted", path: student_assignment_path(fresh), title: "小テスト詳細・採点結果 | QuickFlow")
    visit student_assignment_pdf_preview_path(fresh)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    audit("student-pdf", path: student_assignment_pdf_preview_path(fresh), title: "小テストの解答 | QuickFlow")
    expect(page).to have_no_link("小テスト詳細へ戻る")
    expect(page).to have_no_css("footer")
  end
end
