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
    @assignment.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/pdf_preview_single.pdf")),
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

  it "partially erases only ink and replays pen/eraser/pen after resize and high-DPI rendering" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_text("1ページ目を表示しています。", wait: 20)
    expect(find_button("ペン")["aria-pressed"]).to eq("true")
    expect(find_button("消しゴム")["aria-pressed"]).to eq("false")
    original_pdf = find('[data-pdf-preview-target="canvas"]').evaluate_script("this.toDataURL()")
    ink_drag(0.1, 0.1, 0.5, 0.1)
    ink_drag(0.1, 0.12, 0.5, 0.12)
    ink_drag(0.8, 0.1, 0.8, 0.1)
    expect(ink_alpha(0.2, 0.1)).to be > 0

    # Native buttons also activate via keyboard.
    find_button("消しゴム").send_keys(:space)
    click_button "小"
    expect(find_button("消しゴム")["aria-pressed"]).to eq("true")
    expect(find_button("ペン")["aria-pressed"]).to eq("false")
    expect(find('[data-pdf-preview-target="ink"]').evaluate_script("this.style.cursor")).to eq("none")
    ink_drag(0.2, 0.1, 0.2, 0.1)
    ink_drag(0.4, 0.09, 0.4, 0.11)
    expect(ink_alpha(0.2, 0.1)).to eq(0)
    expect(ink_alpha(0.4, 0.1)).to eq(0)
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(ink_alpha(0.3, 0.1)).to be > 0
    expect(ink_alpha(0.45, 0.1)).to be > 0
    expect(ink_alpha(0.4, 0.12)).to be > 0
    expect(ink_alpha(0.8, 0.1)).to be > 0
    expect(find('[data-pdf-preview-target="canvas"]').evaluate_script("this.toDataURL()")).to eq(original_pdf)

    find_button("ペン").send_keys(:enter)
    expect(find_button("ペン")["aria-pressed"]).to eq("true")
    ink_drag(0.2, 0.1, 0.2, 0.1)
    expect(ink_alpha(0.2, 0.1)).to be > 0
    begin
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 800, height: 900,
        deviceScaleFactor: 2, mobile: false)
      Timeout.timeout(5) do
        sleep 0.05 until page.evaluate_script(<<~JS)
          (() => { const c = document.querySelector('[data-pdf-preview-target="ink"]');
            return !c.hidden && devicePixelRatio === 2 && Math.abs(c.width-c.getBoundingClientRect().width*2) <= 1; })()
        JS
      end
      expect(ink_alpha(0.2, 0.1)).to be > 0
      expect(ink_alpha(0.4, 0.1)).to eq(0)
      expect(ink_alpha(0.45, 0.1)).to be > 0
      expect(ink_alpha(0.4, 0.12)).to be > 0
      expect(ink_alpha(0.8, 0.1)).to be > 0
      assert_canvas
      click_button "消しゴム"
    click_button "小"
      page.driver.browser.action.scroll_by(0, 150).perform
      Timeout.timeout(5) { sleep 0.05 until page.evaluate_script("window.scrollY") > 0 }
      expect(ink_alpha(0.4, 0.1)).to eq(0)
      expect(ink_alpha(0.2, 0.1)).to be > 0
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end

  def ink_drag(x1, y1, x2, y2, number = nil)
    scroll_page(number) if number
    prefix = number ? "[data-page-number='#{number}'] " : ""
    rect = page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector("#{prefix}[data-pdf-preview-target='ink']").getBoundingClientRect();
        return {x:r.x, y:r.y, width:r.width, height:r.height}; })()
    JS
    page.driver.browser.action.move_to_location((rect["x"] + rect["width"] * x1).round, (rect["y"] + rect["height"] * y1).round)
      .pointer_down(:left)
      .move_to_location((rect["x"] + rect["width"] * x2).round, (rect["y"] + rect["height"] * y2).round)
      .pointer_up(:left).perform
  end

  def ink_alpha(x, y, number = nil)
    scroll_page(number) if number
    prefix = number ? "[data-page-number='#{number}'] " : ""
    page.evaluate_script(<<~JS)
      (() => { const c = document.querySelector("#{prefix}[data-pdf-preview-target='ink']");
        return c.getContext('2d').getImageData(Math.round(c.width*#{x}), Math.round(c.height*#{y}), 1, 1).data[3]; })()
    JS
  end

  it "keeps three differently sized/rotated pages independent through erasing, scrolling, resizing and DPR changes" do
    attach_preview("pdf_preview_three.pdf")
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_text("3ページを表示しています。", wait: 30)
    expect(all(".pdf-preview-sheet").map { |sheet| sheet["data-page-number"] }).to eq(%w[1 2 3])
    expect(page).to have_css("canvas", count: 6, visible: :all)
    ratios = page.evaluate_script("Array.from(document.querySelectorAll('.pdf-preview-page')).map(p => p.clientWidth/p.clientHeight)")
    [ 2.0 / 3, 1.5, 1.5 ].each_with_index { |ratio, i| expect(ratios[i]).to be_within(0.01).of(ratio) }
    colors = (1..3).map do |number|
      scroll_page(number)
      find("[data-page-number='#{number}'] [data-pdf-preview-target='canvas']").evaluate_script("Array.from(this.getContext('2d').getImageData(Math.floor(this.width/2),Math.floor(this.height/2),1,1).data)")
    end
    expect(colors).to eq([ [ 0, 0, 0, 255 ], [ 255, 0, 0, 255 ], [ 0, 0, 255, 255 ] ])

    (1..3).each do |number|
      scroll_page(number)
      expect(ink_alpha(0.2, 0.2, number)).to eq(0)
      ink_drag(0.1, 0.2, 0.6, 0.2, number)
      ink_drag(0.8, 0.2, 0.8, 0.2, number)
      expect(ink_alpha(0.2, 0.2, number)).to be > 0
    end
    # Page 2's operations never appear on pages 1 or 3.
    scroll_page(2)
    ink_drag(0.75, 0.3, 0.75, 0.3, 2)
    expect(ink_alpha(0.75, 0.3, 1)).to eq(0)
    expect(ink_alpha(0.75, 0.3, 3)).to eq(0)
    scroll_page(2)
    original = find('[data-page-number="2"] [data-pdf-preview-target="canvas"]').evaluate_script("this.toDataURL()")
    click_button "消しゴム"
    click_button "小"
    ink_drag(0.3, 0.2, 0.3, 0.2, 2)
    ink_drag(0.45, 0.18, 0.45, 0.22, 2)
    expect(ink_alpha(0.3, 0.2, 2)).to eq(0)
    expect(ink_alpha(0.45, 0.2, 2)).to eq(0)
    expect(ink_alpha(0.2, 0.2, 1)).to be > 0
    expect(ink_alpha(0.3, 0.2, 3)).to be > 0
    scroll_page(2)
    expect(find('[data-page-number="2"] [data-pdf-preview-target="canvas"]').evaluate_script("this.toDataURL()")).to eq(original)
    click_button "ペン"
    ink_drag(0.3, 0.2, 0.3, 0.2, 2)
    expect(ink_alpha(0.3, 0.2, 2)).to be > 0

    begin
      page.current_window.resize_to(1000, 900)
      page.current_window.resize_to(900, 900)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 800, height: 900, deviceScaleFactor: 2, mobile: false)
      Timeout.timeout(10) do
        sleep 0.05 until page.evaluate_script(<<~JS)
          Array.from(document.querySelectorAll('[data-pdf-preview-target="ink"]')).some(c =>
            !c.hidden && Math.abs(c.width-c.getBoundingClientRect().width*2) <= 1)
        JS
      end
      (1..3).each do |number|
        scroll_page(number)
        expect(ink_alpha(0.2, 0.2, number)).to be > 0
        expect(ink_alpha(0.8, 0.2, number)).to be > 0
      end
      expect(ink_alpha(0.45, 0.2, 2)).to eq(0)
      expect(ink_alpha(0.3, 0.2, 2)).to be > 0
      expect(ink_alpha(0.75, 0.3, 1)).to eq(0)
      expect(ink_alpha(0.75, 0.3, 2)).to be > 0
      expect(find_button("ペン")["aria-pressed"]).to eq("true")
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end

  it "ends captured input at a page boundary without drawing on the next page" do
    page.current_window.resize_to(800, 1100)
    attach_preview("pdf_preview_three.pdf")
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_text("3ページを表示しています。", wait: 30)
    scroll_page(2)
    rect = find('[data-page-number="2"] [data-pdf-preview-target="ink"]').evaluate_script("this.getBoundingClientRect().toJSON()")
    x = (rect["x"] + rect["width"] * 0.2).round
    y = (rect["bottom"] - 20).round
    page.driver.browser.action.move_to_location(x, y).pointer_down(:left)
      .move_to_location(x, (rect["bottom"] + 40).round).pointer_up(:left).perform
    expect(ink_alpha(0.2, 0.05, 3)).to eq(0)
    scroll_page(3)
    ink_drag(0.2, 0.2, 0.2, 0.2, 3)
    expect(ink_alpha(0.2, 0.2, 3)).to be > 0
    scroll_page(2)
    expect(ink_alpha(0.2, 0.2, 2)).to eq(0)
  end

  it "renders ten pages sequentially with a bounded total bitmap allocation and can leave the screen" do
    attach_preview("pdf_preview_ten.pdf")
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_text("10ページを表示しています。", wait: 30)
    expect(page).to have_css("canvas", count: 20, visible: :all)
    pixels = page.evaluate_script("Array.from(document.querySelectorAll('canvas')).reduce((sum,c) => sum+c.width*c.height,0)")
    expect(pixels).to be <= 32_100_000
    scroll_page(10)
    ink_drag(0.2, 0.2, 0.2, 0.2, 10)
    expect(ink_alpha(0.2, 0.2, 10)).to be > 0
    click_link "小テストの詳細へ戻る"
    expect(page).to have_current_path(student_assignment_path(@assignment))
    expect(page).to have_css('input[type="file"]')
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_text("10ページを表示しています。", wait: 30)
    expect(ink_alpha(0.2, 0.2, 10)).to eq(0)
  end

  def scroll_page(number)
    find("[data-page-number='#{number}']").execute_script("this.scrollIntoView({block:'start'})")
    expect(page).to have_css("[data-page-number='#{number}'] [data-pdf-preview-target='ink']", visible: true, wait: 15)
  end

  it "offers three erase widths, remembers selection, and restores each recorded footprint" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_text("1ページ目を表示しています。", wait: 20)
    expect(page).to have_no_css('[data-pdf-preview-target="sizes"]', visible: true)
    ink_drag(0.1, 0.2, 0.9, 0.2)
    original = find('[data-pdf-preview-target="canvas"]').evaluate_script("this.toDataURL()")
    click_button "消しゴム"
    expect(find_button("中")["aria-pressed"]).to eq("true")
    expect(page).to have_css('[data-pdf-preview-target="size"]', count: 3)
    [ [ "小", 0.2, 4 ], [ "中", 0.4, 8 ], [ "大", 0.6, 12 ] ].each do |label, x, width|
      find_button(label).send_keys(:space)
      expect(find_button(label)["aria-pressed"]).to eq("true")
      ink_drag(x, 0.2, x, 0.2)
      expect(ink_alpha(x, 0.2)).to eq(0)
      geometry = page.evaluate_script(<<~JS)
        (() => { const c = document.querySelector('[data-pdf-preview-target="ink"]');
          return {pageWidth:c.getBoundingClientRect().width,
            cursor:document.querySelector('.pdf-preview-eraser-cursor').getBoundingClientRect().width}; })()
      JS
      expect(geometry["cursor"]).to be_within(0.5).of(geometry["pageWidth"] * width / 200)
    end
    expect(ink_alpha(0.215, 0.2)).to be > 0 # Outside small radius.
    expect(ink_alpha(0.415, 0.2)).to eq(0) # Inside medium radius.
    expect(ink_alpha(0.425, 0.2)).to be > 0
    expect(ink_alpha(0.625, 0.2)).to eq(0) # Inside large radius.
    expect(ink_alpha(0.635, 0.2)).to be > 0
    expect(find('[data-pdf-preview-target="canvas"]').evaluate_script("this.toDataURL()")).to eq(original)
    click_button "ペン"
    expect(page).to have_no_css('[data-pdf-preview-target="sizes"]', visible: true)
    click_button "消しゴム"
    expect(find_button("大")["aria-pressed"]).to eq("true")
    click_button "小"
    page.current_window.resize_to(800, 900)
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script(<<~JS)
        (() => { const c = document.querySelector('[data-pdf-preview-target="ink"]');
          return !c.hidden && Math.abs(c.width-c.getBoundingClientRect().width*Math.min(devicePixelRatio,2)) <= 1; })()
      JS
    end
    expect(ink_alpha(0.215, 0.2)).to be > 0
    expect(ink_alpha(0.415, 0.2)).to eq(0)
    expect(ink_alpha(0.625, 0.2)).to eq(0)
  end

  it "restores all erase sizes after releasing offscreen canvases without moving page geometry" do
    attach_preview("pdf_preview_ten.pdf")
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_text("10ページを表示しています。", wait: 30)
    scroll_page(1)
    ink_drag(0.1, 0.2, 0.9, 0.2, 1)
    click_button "消しゴム"
    [ [ "小", 0.2 ], [ "中", 0.4 ], [ "大", 0.6 ] ].each do |label, x|
      click_button label
      ink_drag(x, 0.2, x, 0.2, 1)
    end
    saved = find('[data-page-number="1"] [data-pdf-preview-target="ink"]').evaluate_script("this.toDataURL()")
    positions = page.evaluate_script("Array.from(document.querySelectorAll('.pdf-preview-sheet')).map(s=>s.getBoundingClientRect().top+scrollY)")
    scroll_page(10)
    expect(find_button("大")["aria-pressed"]).to eq("true")
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("document.querySelector('[data-page-number=\"1\"] canvas').width === 0")
    end
    click_button "ペン"
    ink_drag(0.1, 0.2, 0.9, 0.2, 10)
    click_button "消しゴム"
    ink_drag(0.6, 0.2, 0.6, 0.2, 10)
    expect(ink_alpha(0.625, 0.2, 10)).to eq(0)
    scroll_page(1)
    expect(find('[data-page-number="1"] [data-pdf-preview-target="ink"]').evaluate_script("this.toDataURL()")).to eq(saved)
    expect(page.evaluate_script("Array.from(document.querySelectorAll('.pdf-preview-sheet')).map(s=>s.getBoundingClientRect().top+scrollY)")).to eq(positions)
    before = page.evaluate_script("scrollY")
    sleep 0.2
    expect(page.evaluate_script("scrollY")).to eq(before)
  end

  it "measures one, three and ten page previews at the same viewport and DPR" do
    begin
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 800, height: 900, deviceScaleFactor: 2, mobile: false)
      [ [ "pdf_preview_single.pdf", 1 ], [ "pdf_preview_three.pdf", 3 ], [ "pdf_preview_ten.pdf", 10 ] ].each do |filename, count|
        attach_preview(filename)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        visit student_assignment_pdf_preview_path(@assignment)
        expect(page).to have_css('[data-page-number="1"] [data-pdf-preview-target="ink"]', visible: true, wait: 30)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        metrics = page.evaluate_script(<<~JS)
          (() => { const c = document.querySelector('canvas'); const r=c.getBoundingClientRect();
            const all=Array.from(document.querySelectorAll('canvas'));
            return {density:c.width/r.width, pixels:all.reduce((n,c)=>n+c.width*c.height,0),
              resident:all.filter(c=>c.width>0).length/2, total:#{count}}; })()
        JS
        expect(metrics["density"]).to be_within(0.01).of(2)
        expect(metrics["pixels"]).to be <= 32_100_000
        expect(metrics["resident"]).to be < count if count == 10
        puts "B2_METRIC #{metrics.merge("elapsed_seconds" => elapsed.round(3), "rgba_mb" => (metrics["pixels"] * 4 / 1_000_000.0).round(2)).to_json}"
      end
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end

  it "accepts touch size buttons and ignores extra touch while a pen is down" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_text("1ページ目を表示しています。", wait: 20)
    [ "消しゴム", "大" ].each do |label|
      rect = find_button(label).evaluate_script("this.getBoundingClientRect().toJSON()")
      action = page.driver.browser.action
      action.add_pointer_input(:touch, "size-touch")
      action.move_to_location((rect["x"] + rect["width"] / 2).round, (rect["y"] + rect["height"] / 2).round, device: "size-touch")
        .pointer_down(:left, device: "size-touch").pointer_up(:left, device: "size-touch").perform
    end
    expect(find_button("大")["aria-pressed"]).to eq("true")
    click_button "ペン"
    rect = find('[data-pdf-preview-target="ink"]').evaluate_script("this.getBoundingClientRect().toJSON()")
    x = (rect["x"] + rect["width"] * 0.2).round
    y = (rect["y"] + rect["height"] * 0.1).round
    pen = page.driver.browser.action
    pen.add_pointer_input(:pen, "held-pen")
    pen.move_to_location(x, y, device: "held-pen").pointer_down(:left, device: "held-pen").perform
    before = page.evaluate_script("scrollY")
    touch = page.driver.browser.action
    touch.add_pointer_input(:touch, "extra-touch")
    touch.move_to_location(x + 50, y + 20, device: "extra-touch").pointer_down(:left, device: "extra-touch")
      .move_to_location(x + 50, y, device: "extra-touch").pointer_up(:left, device: "extra-touch").perform
    expect(page.evaluate_script("scrollY")).to eq(before)
    pen = page.driver.browser.action
    pen.add_pointer_input(:pen, "held-pen")
    pen.pointer_up(:left, device: "held-pen").perform
    expect(ink_alpha(0.2, 0.1)).to be > 0
  end

  def attach_preview(filename)
    @assignment.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files", filename)),
      filename: "preview.pdf", content_type: "application/pdf")
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

    click_button "消しゴム"
    click_button "小"
    actions = page.driver.browser.action
    actions.add_pointer_input(:pen, "test-pen")
    actions.move_to_location((bounds["x"] + bounds["width"] * 0.15).round, y, device: "test-pen")
      .pointer_down(:left, device: "test-pen").pointer_up(:left, device: "test-pen").perform
    expect(ink_alpha(0.15, 0.1)).to eq(0)

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
