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

  def waiting_geometry
    page.evaluate_script(<<~JS)
      (() => {
        const panel = document.querySelector('.student-grading-panel');
        const waiting = panel.querySelector('.student-grading-waiting');
        const dots = [...waiting.querySelectorAll('.student-grading-waiting__dot')];
        const text = waiting.querySelector('p');
        const rect = element => {
          const r = element.getBoundingClientRect();
          return [r.x, r.y, r.width, r.height];
        };
        const first = dots[0].getBoundingClientRect(), last = dots[2].getBoundingClientRect();
        const bounds = panel.getBoundingClientRect();
        const range = document.createRange(); range.selectNodeContents(text);
        const words = range.getBoundingClientRect();
        const style = getComputedStyle(dots[0]);
        return { panel: rect(panel), waiting: rect(waiting), text: rect(text),
          pdf: rect(document.querySelector('.answer-pdf')),
          pdfPages: rect(document.querySelector('.answer-pdf__pages')),
          pdfOverflow: getComputedStyle(document.querySelector('.answer-pdf__pages')).overflowY,
          dots: dots.map(rect), color: style.backgroundColor, font: getComputedStyle(text).font,
          gap: getComputedStyle(dots[0].parentElement).gap,
          timing: [style.animationDuration, style.animationIterationCount, style.animationTimingFunction],
          delays: dots.map(dot => getComputedStyle(dot).animationDelay),
          y: new DOMMatrixReadOnly(style.transform).m42,
          dotCenter: (first.left + last.right) / 2,
          textCenter: (words.left + words.right) / 2,
          panelCenter: (bounds.left + bounds.right) / 2,
          contained: dots.every(dot => {
            const r = dot.getBoundingClientRect(), b = waiting.getBoundingClientRect();
            return r.left >= b.left && r.right <= b.right && r.top >= b.top && r.bottom <= b.bottom;
          }),
          overflow: document.documentElement.scrollWidth > innerWidth };
      })()
    JS
  end

  def save_waiting_evidence(state, width, phase, geometry)
    return unless ENV["QF_PDF_EVIDENCE"]

    prefix = File.join(ENV.fetch("QF_PDF_EVIDENCE"), "waiting-#{state}-#{width}-#{phase}")
    File.write("#{prefix}.json", JSON.pretty_generate(geometry))
    dimensions = page.evaluate_script("[document.documentElement.clientWidth, document.documentElement.scrollHeight]")
    screenshot = page.driver.browser.execute_cdp("Page.captureScreenshot", captureBeyondViewport: true,
      clip: { x: 0, y: 0, width: dimensions[0], height: dimensions[1], scale: 1 })
    File.binwrite("#{prefix}.png", Base64.decode64(screenshot.fetch("data")))
  end

  [ :submitted, :grading ].each do |state|
    it "centers #{state} dots and guidance horizontally without changing vertical or PDF geometry" do
      submission.update!(status: state)
      [ [ 320, 812 ], [ 375, 812 ], [ 768, 1024 ], [ 1280, 900 ] ].each do |width, height|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
          width: width, height: height, deviceScaleFactor: 1, mobile: false)
        visit student_assignment_path(assignment)
        expect(page.evaluate_script("innerWidth")).to eq(width)
        expect(page).to have_content(state == :submitted ? "採点結果を準備しています。" : "AIが答案を確認しています。")
        expect(page).not_to have_content("時間がかかる場合は、このページを開き直してください。")
        expect(page).to have_css('.student-grading-waiting__dots[aria-hidden="true"]')
        expect(page).to have_css(".student-grading-waiting__dot", count: 3)
        expect(page).to have_css("canvas[data-rendered='true']")
        page.execute_script(<<~JS)
          document.querySelectorAll('.student-grading-waiting__dot').forEach(dot => {
            const animation = dot.getAnimations()[0];
            animation.pause(); animation.currentTime = 900;
          });
        JS
        current = waiting_geometry
        save_waiting_evidence(state, width, "after", current)
        expect(current.fetch("dotCenter")).to be_within(1).of(current.fetch("panelCenter"))
        expect(current.fetch("textCenter")).to be_within(1).of(current.fetch("panelCenter"))
        expect(current.fetch("dots").first.last(2)).to eq([ 28, 28 ])
        expect(current.fetch("y")).to be <= -18
        expect(current.fetch("contained")).to be(true)
        expect(current.fetch("overflow")).to be(false)
        expect(current.fetch("timing")).to eq([ "1.8s", "3", "cubic-bezier(0.45, 0, 0.55, 1)" ])
        expect(current.fetch("delays")).to eq([ "0s", "0.15s", "0.3s" ])
        expect(current.fetch("gap")).to eq("13.6px")
        expect(current.fetch("pdfOverflow")).to eq("auto")
        page.execute_script(<<~JS)
          const style = document.createElement('style');
          style.id = 'previous-waiting-alignment';
          style.textContent = '.student-grading-panel .student-grading-waiting__dots { justify-content: flex-start; } .student-grading-panel .student-grading-waiting p { text-align: left; }';
          document.head.append(style);
        JS
        previous = waiting_geometry
        save_waiting_evidence(state, width, "before", previous)
        page.execute_script("document.getElementById('previous-waiting-alignment').remove()")
        %w[panel waiting text pdf pdfPages pdfOverflow color font gap timing delays overflow].each do |property|
          expect(current.fetch(property)).to eq(previous.fetch(property)), property
        end
        current.fetch("dots").zip(previous.fetch("dots")).each do |actual, prior|
          expect(actual.drop(1)).to eq(prior.drop(1))
        end
        # Retain the earlier dot-size regression check for the PDF rectangle.
        page.execute_script(<<~JS)
          const style = document.createElement('style');
          style.id = 'previous-waiting-size';
          style.textContent = '.student-grading-panel .student-grading-waiting__dot { width: 1.1rem; height: 1.1rem; }';
          document.head.append(style);
        JS
        expect(waiting_geometry.fetch("pdf")).to eq(current.fetch("pdf"))
        page.execute_script("document.getElementById('previous-waiting-size').remove()")
      end
    end
  end

  it "finishes the existing finite dot animation and stays still after a network error" do
    visit student_assignment_path(assignment)
    expect(page).to have_css(".student-grading-waiting__dot", count: 3)
    page.execute_script(<<~JS)
      document.querySelectorAll('.student-grading-waiting__dot').forEach(dot => dot.getAnimations()[0].finish());
    JS
    expect(page.evaluate_script("[...document.querySelectorAll('.student-grading-waiting__dot')].every(dot => getComputedStyle(dot).transform === 'none')")).to be(true)
    page.execute_script("document.getElementById('grading-status').dispatchEvent(new CustomEvent('turbo:fetch-request-error', { bubbles: true }))")
    expect(page).to have_css('.student-grading-panel[data-grading-presentation-paused="true"]')
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.student-grading-waiting__dot')).animationName")).to eq("none")
    expect(page).to have_content("AIが答案を確認しています。")
    page.refresh
    expect(page).to have_css(".student-grading-waiting__dot", count: 3)
    expect(page).not_to have_css('[data-grading-presentation-paused="true"]')
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
    expect(page).not_to have_css(".student-grading-waiting__dot")
  end
end
