require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"
require_relative "../support/ai_grading_context"

RSpec.describe "Normal account read-only answer PDFs", type: :system do
  include_context "AI grading records"

  before do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    expect(OpenAI::Client).not_to receive(:new)
    expect(AiClient).not_to receive(:build)
    question = create_question
    submission.grading_results.create!(question: question, ai_judgment: :correct,
      ai_model_name: "synthetic-display-fixture", prompt_version: "local-fixture", graded_at: Time.current)
    submission.update!(status: :completed)
    submission.answer_file.attach(io: File.open(Rails.root.join("db/demo_samples/answer.pdf")),
      filename: "synthetic-answer.pdf", content_type: "application/pdf")
  end

  it "renders the same authorized PDF for normal teacher and student through navigation and reload" do
    visit login_path
    fill_in "ユーザーID", with: teacher.user_id
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(assignments_path)
    visit assignment_submission_path(assignment, submission)
    verify_render("normal-teacher")
    expect(page).to have_button("保存")
    visit assignments_path
    click_button "ログアウト"
    visit student_login_path
    fill_in "学校コード", with: school.school_code
    select "1年", from: "学年"
    select "1組", from: "クラス番号"
    select "1番", from: "出席番号"
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(student_assignments_path)
    click_link assignment.title
    verify_render("normal-student")
    expect(page).to have_content("現在の点数：5点")
    expect(page).not_to have_button("保存")
  end

  it "keeps multi-page viewing bounded to one canvas and permits selecting every page" do
    submission.answer_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/pdf_preview_three.pdf")),
      filename: "three-pages.pdf", content_type: "application/pdf")
    visit login_path
    fill_in "ユーザーID", with: teacher.user_id
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(assignments_path)
    visit assignment_submission_path(assignment, submission)
    expect(page).to have_css("[data-answer-pdf-target='status']", text: "1 / 3ページ")
    select "3 / 3", from: "表示ページ"
    expect(page).to have_css("[data-answer-pdf-target='status']", text: "3 / 3ページ")
    expect(page).to have_css("canvas[data-rendered='true']", count: 1)
    expect(find("canvas")["aria-label"]).to eq("答案PDF 3 / 3ページ")
    select "2 / 3", from: "表示ページ"
    expect(page).to have_css("[data-answer-pdf-target='status']", text: "2 / 3ページ")
    expect(page).to have_css("canvas", count: 1)
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 900, deviceScaleFactor: 1, mobile: false)
    expect(page).to have_css("canvas[data-rendered='true']", count: 1) do |canvas|
      canvas.evaluate_script("this.isConnected && this.width <= Math.ceil(this.parentElement.offsetWidth * Math.min(devicePixelRatio || 1, 2)) + 1")
    end
    expect(find("canvas")["aria-label"]).to eq("答案PDF 2 / 3ページ")
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  def verify_render(name)
    [ 1280, 320 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: false)
      expect(page.evaluate_script("innerWidth")).to eq(width)
      expect_answer_pixels
      expect(page.evaluate_script("getComputedStyle(document.querySelector('.teacher-review-layout')).gridTemplateColumns.split(' ').length")).to eq(width == 1280 ? 2 : 1)
      expect(page).not_to have_css(".answer-pdf > p:empty", visible: :all)
      page.refresh
      expect_answer_pixels
      visit page.current_path
      expect_answer_pixels
      if ENV["QF_PDF_EVIDENCE"]
        page.execute_script("document.querySelector('.answer-pdf').scrollIntoView({block:'start'})")
        page.save_screenshot(File.join(ENV.fetch("QF_PDF_EVIDENCE"), "#{name}-#{width}.png"))
      end
    end
  end

  def expect_answer_pixels
    expect(page).to have_css("[data-answer-pdf-target='status']", text: "答案PDFを表示しました（1 / 1ページ）。")
    expect(page).to have_css("canvas[data-rendered='true']", count: 1)
    expect(page).not_to have_css("iframe.teacher-answer-pdf, [data-controller='pdf-preview']")
    expect(page.evaluate_script(<<~JS)).to be(true)
      (() => {
        const canvas=document.querySelector('.answer-pdf canvas');
        const pixels=canvas.getContext('2d').getImageData(0,0,canvas.width,canvas.height).data;
        let ink=0;
        for(let i=0;i<pixels.length;i+=16) if(pixels[i+3]>0 && pixels[i]<200 && pixels[i+1]<200 && pixels[i+2]<200) ink++;
        return ink>50 && document.documentElement.scrollWidth<=innerWidth;
      })()
    JS
    expect(page).not_to have_css('.answer-pdf a, .answer-pdf [target="_blank"]', visible: :all)
    expect(page.html).not_to include("PDFを別タブで開く")
  end
end
