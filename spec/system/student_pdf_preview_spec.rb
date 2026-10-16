require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"

RSpec.describe "Student PDF preview in Chrome", type: :system do
  before do
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    school = School.create!(school_code: "PDFSYS")
    teacher = Teacher.create!(school: school, user_id: "pdf-system", password: "password123")
    classroom = Classroom.create!(school: school, grade: 1, class_number: 1)
    Student.create!(classroom: classroom, attendance_number: 1, password: "password123")
    @assignment = Assignment.create!(teacher: teacher, title: "表示試験", point_per_question: 5)
    @assignment.assignment_classrooms.create!(classroom: classroom)
    @assignment.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/pdf_preview.pdf")),
      filename: "preview.pdf", content_type: "application/pdf")

    visit student_login_path
    select "1年", from: "学年"
    select "1組", from: "クラス番号"
    select "1番", from: "出席番号"
    fill_in "学校コード", with: "PDFSYS"
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(student_assignments_path)
  end

  after do
    @browser_script_ids&.each do |identifier|
      page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: identifier)
    end
  end

  it "renders page one with a real local module worker and preserves its aspect ratio after resizing" do
    install_browser_script(<<~JS)
      window.pdfPreviewWorkers = [];
      const NativeWorker = window.Worker;
      window.Worker = class extends NativeWorker {
        constructor(url, options) {
          super(url, options);
          window.pdfPreviewWorkers.push({ url: String(url), type: options.type });
        }
      };
    JS
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_text("1ページ目を表示しています。", wait: 20)
    expect(page).to have_css("canvas", count: 1)
    worker = page.evaluate_script("window.pdfPreviewWorkers")
    expect(worker.size).to eq(1)
    expect(worker.first).to eq("url" => "/vendor/pdfjs/6.4.299/pdf.worker.min.mjs", "type" => "module")
    expect(page.driver.browser.logs.get(:browser).map(&:message).join).not_to include("fake worker")

    assert_canvas
    page.current_window.resize_to(800, 900)
    expect(page).to have_text("1ページ目を表示しています。")
    # Wait for the debounced backing-store resize, not just CSS scaling.
    expect(page).to have_css("canvas", visible: true)
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script(<<~JS)
        (() => { const c = document.querySelector('canvas');
          return Math.abs(c.width - c.getBoundingClientRect().width * Math.min(devicePixelRatio, 2)) <= 1; })()
      JS
    end
    assert_canvas
    resources = page.evaluate_script("performance.getEntriesByType('resource').map(r => r.name)")
    expect(resources).to all(start_with(URI.parse(page.current_url).then { |uri| "#{uri.scheme}://#{uri.host}:#{uri.port}/" }))
    expect(Submission.count).to eq(0)
  end

  it "shows an error instead of a blank canvas when the PDF is corrupt" do
    @assignment.material_file.attach(io: StringIO.new("%PDF-1.7\ninvalid"),
      filename: "broken.pdf", content_type: "application/pdf")
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('[role="alert"]', text: "問題を表示できませんでした", wait: 20)
    expect(page).to have_no_css("canvas", visible: true)
  end

  it "shows an error when the authenticated material endpoint returns 404" do
    @assignment.material_file.detach
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('[role="alert"]', text: "問題を表示できませんでした", wait: 20)
    expect(page).to have_no_css("canvas", visible: true)
  end

  it "shows an error when the real worker fails to load" do
    # A new URL avoids the successful worker module cached by the preceding test.
    # This still creates a real Worker; only its URL is changed to a local 404.
    install_browser_script(<<~JS)
      const WorkingWorker = window.Worker;
      window.Worker = class extends WorkingWorker {
        constructor(url, options) {
          super('/vendor/pdfjs/6.4.299/missing-worker.mjs', options);
        }
      };
    JS
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('[role="alert"]', text: "問題を表示できませんでした", wait: 20)
    expect(page).to have_no_css("canvas", visible: true)
  end

  def install_browser_script(source)
    result = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: source)
    (@browser_script_ids ||= []) << result.fetch("identifier")
  end

  def assert_canvas
    result = page.evaluate_script(<<~JS)
      (() => {
        const c = document.querySelector('canvas');
        const rect = c.getBoundingClientRect();
        const pixel = c.getContext('2d').getImageData(Math.floor(c.width / 2), Math.floor(c.height / 2), 1, 1).data;
        return { ratio: rect.width / rect.height, fits: Math.abs(rect.width - c.parentElement.clientWidth) < 1,
          black: pixel[0] < 10 && pixel[1] < 10 && pixel[2] < 10 && pixel[3] === 255 };
      })()
    JS
    expect(result["ratio"]).to be_within(0.01).of(2.0 / 3)
    expect(result["fits"]).to be(true)
    expect(result["black"]).to be(true)
  end
end
