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
    expect(page).to have_css("canvas", count: 2)
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

  it "draws separate mouse strokes and a dot on a transparent layer and keeps them aligned after resize" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_text("1ページ目を表示しています。", wait: 20)
    overlay = find('[data-pdf-preview-target="ink"]')
    bounds = page.evaluate_script(<<~JS)
      (() => {
        const pdf = document.querySelector('[data-pdf-preview-target="canvas"]').getBoundingClientRect();
        const ink = document.querySelector('[data-pdf-preview-target="ink"]').getBoundingClientRect();
        return {aligned: ['x','y','width','height'].every(k => Math.abs(pdf[k]-ink[k]) < 0.1),
          x: ink.x, y: ink.y, width: ink.width, height: ink.height};
      })()
    JS
    expect(bounds["aligned"]).to be(true)
    y = (bounds["y"] + bounds["height"] * 0.1).round
    actions = page.driver.browser.action
    [ [ 0.1, 0.2 ], [ 0.35, 0.45 ] ].each do |start_x, end_x|
      actions.move_to_location((bounds["x"] + bounds["width"] * start_x).round, y)
        .pointer_down(:left).move_to_location((bounds["x"] + bounds["width"] * end_x).round, y)
        .pointer_up(:left)
    end
    actions.move_to_location((bounds["x"] + bounds["width"] * 0.7).round, y).click.perform
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(ink_alpha(0.4, 0.1)).to be > 0
    expect(ink_alpha(0.7, 0.1)).to be > 0
    expect(ink_alpha(0.275, 0.1)).to eq(0)
    expect(ink_alpha(0.9, 0.1)).to eq(0)
    expect(page.evaluate_script("window.getSelection().toString()")).to eq("")
    expect(overlay["class"]).to include("pdf-preview-ink")

    page.current_window.resize_to(800, 900)
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script(<<~JS)
        (() => { const c = document.querySelector('[data-pdf-preview-target="ink"]');
          return !c.hidden && Math.abs(c.width-c.getBoundingClientRect().width*Math.min(devicePixelRatio,2)) <= 1; })()
      JS
    end
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(ink_alpha(0.7, 0.1)).to be > 0
    expect(ink_alpha(0.275, 0.1)).to eq(0)
    # The PDF itself remains intact and its original black square is still present.
    assert_canvas
    page.driver.browser.action.scroll_by(0, 150).perform
    Timeout.timeout(5) { sleep 0.05 until page.evaluate_script("window.scrollY") > 0 }
    expect(ink_alpha(0.15, 0.1)).to be > 0
    page.refresh
    expect(page).to have_text("1ページ目を表示しています。", wait: 20)
    expect(ink_alpha(0.15, 0.1)).to eq(0)
  end

  def ink_alpha(x, y)
    page.evaluate_script(<<~JS)
      (() => { const c = document.querySelector('[data-pdf-preview-target="ink"]');
        return c.getContext('2d').getImageData(Math.round(c.width*#{x}), Math.round(c.height*#{y}), 1, 1).data[3]; })()
    JS
  end

  it "accepts a browser-generated pen pointer while finger drags scroll without adding ink" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_text("1ページ目を表示しています。", wait: 20)
    bounds = page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector('[data-pdf-preview-target="ink"]').getBoundingClientRect();
        return {x:r.x, y:r.y, width:r.width, height:r.height}; })()
    JS
    y = (bounds["y"] + bounds["height"] * 0.1).round
    actions = page.driver.browser.action
    actions.add_pointer_input(:pen, "test-pen")
    actions.move_to_location((bounds["x"] + bounds["width"] * 0.1).round, y, device: "test-pen")
      .pointer_down(:left, device: "test-pen")
      .move_to_location((bounds["x"] + bounds["width"] * 0.2).round, y, device: "test-pen")
      .pointer_up(:left, device: "test-pen").perform
    expect(ink_alpha(0.15, 0.1)).to be > 0

    before = find('[data-pdf-preview-target="ink"]').evaluate_script("this.toDataURL()")
    actions = page.driver.browser.action
    actions.add_pointer_input(:touch, "test-finger")
    x = (bounds["x"] + bounds["width"] * 0.8).round
    actions.move_to_location(x, y + 100, device: "test-finger")
      .pointer_down(:left, device: "test-finger")
      .move_to_location(x, y, device: "test-finger")
      .pointer_up(:left, device: "test-finger").perform
    Timeout.timeout(5) { sleep 0.05 until page.evaluate_script("window.scrollY") > 0 }
    expect(find('[data-pdf-preview-target="ink"]').evaluate_script("this.toDataURL()")).to eq(before)
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
