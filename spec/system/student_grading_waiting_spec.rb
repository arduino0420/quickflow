require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"
require_relative "../support/ai_grading_context"

RSpec.describe "Student grading waiting presentation", type: :system do
  include_context "AI grading records"

  before do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    submission.update!(status: :grading)
    submission.answer_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/pdf_preview_single.pdf")),
      filename: "synthetic-answer.pdf", content_type: "application/pdf")
    visit student_login_path
    fill_in "学校コード", with: school.school_code
    select "1年", from: "学年"
    select "1組", from: "クラス番号"
    select "1番", from: "出席番号"
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(student_assignments_path)
  end

  after do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
  end

  it "shows larger moving dots without overflow while keeping the status understandable" do
    [ [ 320, 812 ], [ 375, 812 ], [ 768, 1024 ], [ 1280, 900 ] ].each do |width, height|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: height, deviceScaleFactor: 1, mobile: false)
      visit student_assignment_path(assignment)
      expect(page.evaluate_script("innerWidth")).to eq(width)
      expect(page).to have_content("AIが答案を確認しています。")
      expect(page).not_to have_content("時間がかかる場合は、このページを開き直してください。")
      expect(page).to have_css('.student-grading-waiting__dots[aria-hidden="true"]')
      expect(page).to have_css(".student-grading-waiting__dot", count: 3)
      expect(page).to have_css("canvas[data-rendered='true']")
      expect(page.evaluate_script(<<~JS)).to be(true)
        (() => { const left=document.querySelector('.student-grading-left-waiting').getBoundingClientRect();
          const section=document.querySelector('[aria-label="提出した答案PDF"]').getBoundingClientRect();
          const pdf=document.querySelector('.answer-pdf').getBoundingClientRect();
          return left.width > 0 && Math.abs((left.left+left.right)/2-(section.left+section.right)/2) < 2 && left.bottom <= pdf.top; })()
      JS
      geometry = page.evaluate_script(<<~JS)
        (() => {
          const panel = document.querySelector('.student-grading-left-waiting');
          const dot = panel.querySelector('.student-grading-waiting__dot');
          const animation = dot.getAnimations()[0];
          animation.pause(); animation.currentTime = 900;
          const style = getComputedStyle(dot);
          const rect = dot.getBoundingClientRect(), bounds = panel.getBoundingClientRect();
          return { width: rect.width, height: rect.height,
            y: new DOMMatrixReadOnly(style.transform).m42,
            contained: rect.left >= bounds.left && rect.right <= bounds.right && rect.top >= bounds.top && rect.bottom <= bounds.bottom,
            overflow: document.documentElement.scrollWidth > innerWidth };
        })()
      JS
      expect(geometry.fetch("width")).to be >= 28
      expect(geometry.fetch("height")).to be >= 28
      expect(geometry.fetch("y")).to be <= -18
      expect(geometry.fetch("contained")).to be(true)
      expect(geometry.fetch("overflow")).to be(false)
      page.save_screenshot(File.join(ENV.fetch("QF_PDF_EVIDENCE"), "waiting-#{width}.png")) if ENV["QF_PDF_EVIDENCE"]
    end
  end

  it "shows the left waiting area only while submitted or grading" do
    [ :submitted, :grading ].each do |state|
      submission.update!(status: state)
      visit student_assignment_path(assignment)
      expect(page).to have_css(".student-grading-left-waiting", visible: true)
      expect(page).to have_css(".student-grading-waiting__dot", count: 3)
      expect(page).to have_text(state == :submitted ? "採点結果を準備しています。" : "AIが答案を確認しています。")
    end
    submission.update!(status: :completed)
    visit student_assignment_path(assignment)
    expect(page).to have_css(".student-grading-left-waiting", visible: :hidden)
    expect(page).not_to have_css(".student-grading-waiting__dot", visible: true)
    expect(page).to have_css("canvas[data-rendered='true']")
  end

  it "keeps reduced motion still and preserves the real failure guidance" do
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia",
      features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
    visit student_assignment_path(assignment)
    expect(page).to have_content("AIが答案を確認しています。")
    expect(page.evaluate_script(<<~JS)).to eq([ "none", "none", "1" ])
      (() => { const s = getComputedStyle(document.querySelector('.student-grading-waiting__dot'));
        return [s.animationName, s.transform, s.opacity]; })()
    JS
    submission.update!(status: :failed)
    visit student_assignment_path(assignment)
    expect(page).to have_content("採点に失敗しました。先生に確認してください。")
    expect(page).not_to have_css(".student-grading-waiting__dot", visible: true)
    expect(page).to have_css(".student-grading-left-waiting", visible: :hidden)
  end
end
