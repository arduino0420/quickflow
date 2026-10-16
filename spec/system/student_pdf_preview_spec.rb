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
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(page).to have_css("canvas", count: 2)
    worker = page.evaluate_script("window.pdfPreviewWorkers")
    expect(worker.size).to eq(1)
    expect(worker.first).to eq("url" => "/vendor/pdfjs/6.4.299/pdf.worker.min.mjs", "type" => "module")
    expect(page.driver.browser.logs.get(:browser).map(&:message).join).not_to include("fake worker")

    assert_canvas
    page.current_window.resize_to(800, 900)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
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
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
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
    expect(page).to have_text("保存済み", wait: 10)
    page.refresh
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(ink_alpha(0.15, 0.1)).to be > 0
  end

  it "partially erases only ink and replays pen/eraser/pen after resize and high-DPI rendering" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
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
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
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
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
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
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(page).to have_css("canvas", count: 20, visible: :all)
    pixels = page.evaluate_script("Array.from(document.querySelectorAll('canvas')).reduce((sum,c) => sum+c.width*c.height,0)")
    expect(pixels).to be <= 32_100_000
    scroll_page(10)
    ink_drag(0.2, 0.2, 0.2, 0.2, 10)
    expect(ink_alpha(0.2, 0.2, 10)).to be > 0
    expect(page).to have_text("保存済み", wait: 10)
    click_link "小テストの詳細へ戻る"
    expect(page).to have_current_path(student_assignment_path(@assignment))
    expect(page).to have_css('input[type="file"]')
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(ink_alpha(0.2, 0.2, 10)).to be > 0
  end

  def scroll_page(number)
    find("[data-page-number='#{number}']").execute_script("this.scrollIntoView({block:'start'})")
    expect(page).to have_css("[data-page-number='#{number}'] [data-pdf-preview-target='ink']", visible: true, wait: 15)
    page.evaluate_async_script("const done=arguments[arguments.length-1]; requestAnimationFrame(()=>requestAnimationFrame(done))")
  end

  it "offers three erase widths, remembers selection, and restores each recorded footprint" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
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
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
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
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
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

  [ [ "pdf_preview_single.pdf", 1 ], [ "pdf_preview_three.pdf", 3 ], [ "pdf_preview_ten.pdf", 10 ] ].each do |filename, count|
    it "downloads and reopens #{count} pages including offscreen ink, ordered erasing and preserved source vectors" do
      attach_preview(filename)
      if count == 3
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 1280, height: 900, deviceScaleFactor: 2, mobile: false)
      end
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      expect(page).not_to have_text("書いた内容は保存されません")
      expect(page).not_to have_text("ページを表示しています")
      expect(page).not_to have_css(".pdf-preview-page-number")
      expect(page).to have_link("小テストの詳細へ戻る")
      ink_drag(0.1, 0.08, 0.35, 0.08, 1)
      ink_drag(0.1, 0.08, 0.35, 0.08, count) if count > 1
      reading_jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == AnswerReadingJob }
      scroll_page(1)
      if count == 3
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 900, height: 900, deviceScaleFactor: 2, mobile: false)
        page.execute_script("document.body.style.zoom = '1.1'")
        expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      end
      page.execute_script(<<~JS)
        const c = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'), 'pdf-preview');
        window.exportSourceOperations = JSON.stringify(c.pageStates.map(s => [...s.ink.pages.values()]));
        window.materialRequests = () => performance.getEntriesByType('resource').filter(r => new URL(r.name).pathname === new URL(c.urlValue, location.href).pathname).length;
        window.sourceRequestCount = window.materialRequests();
        window.exportBlobs = [];
        const nativeURL = URL.createObjectURL;
        URL.createObjectURL = blob => { window.exportBlobs.push(blob); window.exportGenerationMs = performance.now()-window.exportStartedAt; return nativeURL(blob); };
        document.addEventListener('click', e => { if(e.target.download) {window.exportFilename = e.target.download; e.preventDefault();} });
        window.exportStartedAt = performance.now();
        c.download(); c.download();
        window.exportLocked = c.exporting && c.downloadTarget.disabled && c.toolTargets.every(b => b.disabled);
      JS
      expect(page).to have_text("確認用PDFをダウンロードしました", wait: 40)
      expect(page.evaluate_script("window.exportLocked")).to be(true)
      expect(page.evaluate_script("window.exportBlobs.length")).to eq(1)
      expect(page.evaluate_script("window.exportFilename")).to eq("quickflow_answer_assignment_#{@assignment.id}.pdf")
      expect(page.evaluate_script("window.exportBlobs[0].type")).to eq("application/pdf")
      result = page.evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1];
        (async () => {
          const c = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'), 'pdf-preview');
          const {getDocument} = await import('pdfjs');
          const output = await getDocument({data: new Uint8Array(await window.exportBlobs[0].arrayBuffer()), worker:c.pdfWorker}).promise;
          const results = [];
          for (let n=1;n<=output.numPages;n++) {
            const p = await output.getPage(n), original = await c.pdf.getPage(n);
            const v=p.getViewport({scale:2}), before=original.getViewport({scale:2});
            const canvas=document.createElement('canvas'); canvas.width=v.width; canvas.height=v.height;
            const ctx=canvas.getContext('2d');
            await p.render({canvasContext:ctx,viewport:v}).promise;
            const pixel=(x,y)=>Array.from(ctx.getImageData(Math.round(v.width*x),Math.round(v.height*y),1,1).data);
            results.push({size:[v.width,v.height], originalSize:[before.width,before.height],
              ink:pixel(.22,.08), untouched:pixel(.8,.08), center:pixel(.5,.5),
              text:(await p.getTextContent()).items.map(i=>i.str), originalText:(await original.getTextContent()).items.map(i=>i.str)});
            canvas.width=canvas.height=0;
          }
          done({pages:results, count:output.numPages, bytes:window.exportBlobs[0].size,
            milliseconds:window.exportGenerationMs,
            reusedSource:window.sourceRequestCount===window.materialRequests(),
            localResources:performance.getEntriesByType('resource').every(r=>new URL(r.name).origin===location.origin),
            retained:window.exportSourceOperations===JSON.stringify(c.pageStates.map(s=>[...s.ink.pages.values()]))});
        })().catch(e=>done({error:String(e)}));
      JS
      expect(result["error"]).to be_nil
      expect(result["count"]).to eq(count)
      expect(result["retained"]).to be(true)
      expect(result["reusedSource"]).to be(true)
      expect(result["localResources"]).to be(true)
      result.fetch("pages").each_with_index do |item, index|
        expect(item["size"]).to eq(item["originalSize"])
        expect(item["text"]).to eq(item["originalText"])
        color = count == 3 ? [ [ 0, 0, 0 ], [ 255, 0, 0 ], [ 0, 0, 255 ] ][index] : [ 0, 0, 0 ]
        expect(item["center"].first(3)).to eq(color)
        expect(item["untouched"].first(3)).to eq([ 255, 255, 255 ])
        if index == 0 || index == count - 1
          expect(item["ink"].first(3).max).to be < 80
        else
          expect(item["ink"].first(3)).to eq([ 255, 255, 255 ])
        end
      end
      expect(Submission.where(assignment: @assignment)).to be_empty
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == AnswerReadingJob }).to eq(reading_jobs_before)
      puts "C_EXPORT_METRIC #{result.except("pages", "retained").to_json}"
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if count == 3
    end
  end

  it "retries after PNG failure without losing ink and keeps download separate from submission" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    ink_drag(0.1, 0.1, 0.3, 0.1)
    page.execute_script(<<~JS)
      window.nativeToBlob = HTMLCanvasElement.prototype.toBlob;
      HTMLCanvasElement.prototype.toBlob = function(callback) { callback(null); };
    JS
    click_button "確認用PDFをダウンロード"
    expect(page).to have_text("PDFを生成できませんでした", wait: 30)
    expect(ink_alpha(0.2, 0.1)).to be > 0
    expect(page).to have_button("確認用PDFをダウンロード", disabled: false)
    page.execute_script("HTMLCanvasElement.prototype.toBlob = window.nativeToBlob")
    click_button "確認用PDFをダウンロード"
    expect(page).to have_text("確認用PDFをダウンロードしました", wait: 30)
    expect(ink_alpha(0.2, 0.1)).to be > 0
    expect(Submission.where(assignment: @assignment)).to be_empty
  end

  it "exports rotations, offset CropBoxes, all eraser widths, dots and rewritten ink independently of screen resolution" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    result = page.evaluate_async_script(<<~JS)
      const done=arguments[arguments.length-1];
      (async()=>{
        const {PDFDocument,degrees,rgb,StandardFonts}=await import('pdf-lib');
        const {generateAnswerPdf}=await import('pdf_export');
        const {getDocument}=await import('pdfjs');
        const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        const doc=await PDFDocument.create(), font=await doc.embedFont(StandardFonts.Helvetica);
        for(const rotation of [0,90,180,270]) {
          const p=doc.addPage([320,400]); p.setCropBox(20,30,240,300); p.setRotation(degrees(rotation));
          p.drawText('x^2 + 1/2 = 0.5',{x:40,y:300,size:12,font});
          p.drawRectangle({x:30,y:50,width:210,height:180,color:rgb(1,0,0)});
        }
        const source=await doc.save();
        const input=await getDocument({data:source.slice(),worker:c.pdfWorker}).promise;
        const pages=[];
        const stroke=(tool,width,points)=>({tool,width,color:'#000000',points});
        for(let n=1;n<=4;n++) {
          const page=await input.getPage(n), operations=[];
          for(const [i,width] of [4,8,12].entries()) {
            const y=80+i*45;
            operations.push(stroke('pen',1.2,[[40,y],[220,y]]), stroke('eraser',width,[[120,y-10],[120,y+10]]));
          }
          operations.push(stroke('pen',1.2,[[180,260]]),stroke('pen',1.2,[[110,200],[130,200]]));
          pages.push({page,operations});
        }
        const started=performance.now();
        const bytes=await generateAnswerPdf({source,pages});
        const output=await getDocument({data:bytes.slice(),worker:c.pdfWorker}).promise;
        const checks=[];
        for(let n=1;n<=4;n++) {
          const original=pages[n-1].page, p=await output.getPage(n), v=p.getViewport({scale:3});
          const canvas=document.createElement('canvas');canvas.width=v.width;canvas.height=v.height;
          const ctx=canvas.getContext('2d');await p.render({canvasContext:ctx,viewport:v}).promise;
          const pixel=(x,y)=>{const [a,b]=v.convertToViewportPoint(x,y);return Array.from(ctx.getImageData(Math.round(a),Math.round(b),1,1).data).slice(0,3);};
          const erasers=[4,8,12].map((w,i)=>({gap:pixel(120,80+i*45),edge:pixel(120+w/2+1,80+i*45),inside:pixel(120+w/2-1,80+i*45)}));
          checks.push({rotation:p.rotate,view:p.view,originalView:original.view,
            text:(await p.getTextContent()).items.map(i=>i.str).join(''),
            dot:pixel(180,260),rewritten:pixel(120,200),erasers});
          if(n===1) window.phaseCVisual=canvas.toDataURL('image/png');
          canvas.width=canvas.height=0;
        }
        const loaded=await PDFDocument.load(bytes);
        let signedRejected=false,largeRejected=false;
        const signed=await PDFDocument.load(source);
        const {PDFName}=await import('pdf-lib');signed.context.register(signed.context.obj({Type:'Sig',ByteRange:[0,1,2,3]}));
        try {await generateAnswerPdf({source:await signed.save(),pages});}catch{signedRejected=true;}
        const tooLarge=[...pages];tooLarge[0]={...pages[0],page:{view:[0,0,10000,10000],getViewport:()=>({width:40000,height:40000})}};
        try {await generateAnswerPdf({source,pages:tooLarge});}catch{largeRejected=true;}
        done({checks,bytes:bytes.length,milliseconds:performance.now()-started,signedRejected,largeRejected,
          embeddedImages:loaded.getPages().map(p=>p.node.Resources().lookup(PDFName.of('XObject')).keys().length)});

      })().catch(e=>done({error:String(e),stack:e.stack}));
    JS
    expect(result["error"]).to be_nil, result.inspect
    expect(result["signedRejected"]).to be(true)
    expect(result["largeRejected"]).to be(true)
    expect(result["embeddedImages"]).to eq([ 1, 1, 1, 1 ])
    expect(result.fetch("checks").map { |item| item["rotation"] }).to eq([ 0, 90, 180, 270 ])
    result.fetch("checks").each do |item|
      expect(item["view"]).to eq(item["originalView"])
      expect(item["text"]).to include("x^2 + 1/2 = 0.5")
      expect(item["dot"].max).to be < 80
      expect(item["rewritten"].max).to be < 80
      item["erasers"].each do |eraser|
        expect(eraser["gap"]).to eq([ 255, 0, 0 ])
        expect(eraser["inside"]).to eq([ 255, 0, 0 ])
        expect(eraser["edge"].max).to be < 80
      end
    end
    FileUtils.mkdir_p(Rails.root.join("tmp/pdfs"))
    require "base64"
    File.binwrite(Rails.root.join("tmp/pdfs/phase-c-composite.png"), Base64.decode64(page.evaluate_script("window.phaseCVisual").split(",").last))
  end

  it "shows the submitted score with the title weight and a smaller scoped font without changing its value" do
    student = Student.find_by!(attendance_number: 1)
    submission = Submission.create!(assignment: @assignment, student: student, submitted_at: Time.current, status: :completed)
    question = @assignment.questions.create!(question_label: "1", position: 1, question_text: "1+1", correct_answer: "2", grading_rule: "一致",
      answer_generation_model: "test", answer_generation_prompt_version: "v1", answer_generated_at: Time.current)
    submission.grading_results.create!(question: question, ai_judgment: :correct,
      student_answer: "2", ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    visit student_assignments_path
    expect(page).to have_css(".student-card-score", text: "5点")
    styles = page.evaluate_script(<<~JS)
      (()=>{const card=document.querySelector('.assignment-card--submitted');
        const title=getComputedStyle(card.querySelector('.assignment-list-title'));
        const score=getComputedStyle(card.querySelector('.student-card-score'));
        return {title:title.fontWeight,score:score.fontWeight,size:parseFloat(score.fontSize),root:parseFloat(getComputedStyle(document.documentElement).fontSize)};})()
    JS
    expect(styles["score"]).to eq(styles["title"])
    expect(styles["size"]).to be_within(0.1).of(styles["root"] * 1.1)
    expect(styles["size"]).to be < styles["root"] * 1.4
    page.save_screenshot(Rails.root.join("tmp/pdfs/phase-c-score.png"))
  end

  it "measures one, three and ten A4 pages with mathematical ink at 240dpi using one temporary canvas at a time" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    result = using_wait_time(60) do
      page.evaluate_async_script(<<~JS)
      const done=arguments[arguments.length-1];
      (async()=>{
        const {PDFDocument}=await import('pdf-lib'), {getDocument}=await import('pdfjs');
        const {generateAnswerPdf}=await import('pdf_export');
        const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        const results=[];
        for(const count of [1,3,10]) {
          const doc=await PDFDocument.create();for(let n=0;n<count;n++) doc.addPage([595,842]);
          const source=await doc.save(), input=await getDocument({data:source.slice(),worker:c.pdfWorker}).promise;
          const pages=[];
          for(let n=1;n<=count;n++) {
            // Fraction bar, numerator/denominator, superscript and decimal dot.
            const lines=[[[60,700],[110,700]],[[70,710],[80,720],[90,710]],[[75,680],[90,680]],[[100,730],[105,735],[110,730]],[[115,700]]];
            pages.push({page:await input.getPage(n),operations:lines.map((points,id)=>({id,tool:'pen',width:1.2,color:'#000000',points}))});
          }
          const native=document.createElement.bind(document), canvases=[];
          document.createElement=function(tag,...args) {const node=native(tag,...args);if(tag==='canvas')canvases.push(node);return node;};
          let bytes;const started=performance.now();
          try {bytes=await generateAnswerPdf({source,pages});}finally{document.createElement=native;}
          const milliseconds=performance.now()-started;
          const reopened=await getDocument({data:bytes.slice(),worker:c.pdfWorker}).promise;
          results.push({count,outputPages:reopened.numPages,bytes:bytes.length,milliseconds,
            released:canvases.every(canvas=>canvas.width===0&&canvas.height===0),temporaryCanvases:canvases.length});
        }
        done({results});
      })().catch(error=>done({error:String(error)}));
      JS
    end
    expect(result["error"]).to be_nil, result.inspect
    result.fetch("results").each do |metric|
      expect(metric["outputPages"]).to eq(metric["count"])
      expect(metric["temporaryCanvases"]).to eq(metric["count"])
      expect(metric["released"]).to be(true)
      puts "C_A4_EXPORT_METRIC #{metric.to_json}"
    end
  end

  context "server drafts" do
    it "restores all pages, erase widths and pen/erase/pen after reload, resizing, logout and another browser session" do
      attach_preview("pdf_preview_three.pdf")
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      ink_drag(0.1, 0.25, 0.9, 0.25, 1)
      click_button "消しゴム"
      [ [ "小", 0.2 ], [ "中", 0.4 ], [ "大", 0.6 ] ].each do |label, x|
        click_button label
        ink_drag(x, 0.25, x, 0.25, 1)
      end
      click_button "ペン"
      ink_drag(0.4, 0.25, 0.4, 0.25, 1)
      ink_drag(0.8, 0.25, 0.8, 0.25, 3)
      expect(page).to have_text("保存済み", wait: 10)
      draft = AnswerDraft.find_by!(assignment: @assignment)
      expect(draft.page_data.length).to eq(3)
      expect(draft.page_data.first["operations"].select { |op| op["tool"] == "eraser" }.map { |op| op["width"] }).to eq([ 4, 8, 12 ])
      page.current_window.resize_to(900, 900)
      page.refresh
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      expect(page).to have_text("保存済み")
      expect(ink_alpha(0.2, 0.25, 1)).to eq(0)
      expect(ink_alpha(0.4, 0.25, 1)).to be > 0
      expect(ink_alpha(0.6, 0.25, 1)).to eq(0)
      expect(ink_alpha(0.8, 0.25, 3)).to be > 0
      page.execute_script(<<~JS)
        const native = URL.createObjectURL;
        URL.createObjectURL = blob => {window.restoredPdf=blob;return native(blob)};
      JS
      click_button "確認用PDFをダウンロード"
      expect(page).to have_text("確認用PDFをダウンロードしました", wait: 30)
      pixels = page.evaluate_async_script(<<~JS)
        const done=arguments[arguments.length-1];
        (async()=>{
          const {getDocument}=await import('pdfjs');
          const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
          const pdf=await getDocument({data:new Uint8Array(await window.restoredPdf.arrayBuffer()),worker:c.pdfWorker}).promise;
          const results=[];
          for(const [n,x] of [[1,.2],[1,.4],[3,.8]]) {
            const p=await pdf.getPage(n),v=p.getViewport({scale:3});const canvas=document.createElement('canvas');
            canvas.width=v.width;canvas.height=v.height;const ctx=canvas.getContext('2d');
            await p.render({canvasContext:ctx,viewport:v}).promise;
            results.push(Array.from(ctx.getImageData(Math.round(v.width*x),Math.round(v.height*.25),1,1).data).slice(0,3));
            canvas.width=canvas.height=0;
          }
          done(results);
        })().catch(e=>done({error:String(e)}));
      JS
      expect(pixels.first).to eq([ 255, 255, 255 ])
      expect(pixels[1].max).to be < 20
      expect(pixels[2].max).to be < 20
      visit student_assignments_path
      click_button "ログアウト"
      expect(page).to have_field("学校コード", wait: 10)
      login_draft_student
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      expect(ink_alpha(0.4, 0.25, 1)).to be > 0
      using_session(:other_device) do
        login_draft_student
        visit student_assignment_pdf_preview_path(@assignment)
        expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
        expect(ink_alpha(0.2, 0.25, 1)).to eq(0)
        expect(ink_alpha(0.8, 0.25, 3)).to be > 0
      end
      expect(Submission.where(assignment: @assignment)).to be_empty
    end

    it "keeps edits made during a save and debounces consecutive strokes" do
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      page.execute_script(<<~JS)
        const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        const native=c.draft.request;window.draftPuts=0;
        c.draft.request=(url,options)=>{
          if(options.method==='PUT' && ++window.draftPuts===1) return new Promise(resolve=>window.releaseDraftSave=()=>resolve(native(url,options)));
          return native(url,options);
        };
      JS
      ink_drag(0.1, 0.15, 0.2, 0.15)
      ink_drag(0.3, 0.15, 0.4, 0.15)
      expect(page).to have_text("保存中…", wait: 8)
      expect(page.evaluate_script("window.draftPuts")).to eq(1)
      ink_drag(0.5, 0.15, 0.6, 0.15)
      page.execute_script("window.releaseDraftSave()")
      expect(page).to have_text("保存済み", wait: 12)
      expect(page.evaluate_script("window.draftPuts")).to eq(2)
      expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].length).to eq(3)
    end

    it "preserves unsaved ink after a network error and saves it on retry" do
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      page.execute_script(<<~JS)
        const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        window.draftNativeRequest=c.draft.request;c.draft.request=async()=>{throw new TypeError('offline')};
      JS
      ink_drag(0.1, 0.2, 0.6, 0.2, 1)
      expect(page).to have_text("保存できませんでした", wait: 8)
      expect(ink_alpha(0.3, 0.2)).to be > 0
      expect(AnswerDraft.where(assignment: @assignment)).to be_empty
      page.execute_script(<<~JS)
        const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        c.draft.request=window.draftNativeRequest;
      JS
      click_button "保存を再試行"
      expect(page).to have_text("保存済み", wait: 10)
      page.refresh
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      expect(ink_alpha(0.3, 0.2)).to be > 0
    end

    it "stops a stale tab without overwriting the other tab or dropping local strokes" do
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      ink_drag(0.1, 0.2, 0.6, 0.2, 1)
      expect(page).to have_text("保存済み", wait: 10)
      first = current_window
      second = open_new_window
      within_window(second) do
        visit student_assignment_pdf_preview_path(@assignment)
        expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
        ink_drag(0.1, 0.3, 0.6, 0.3, 1)
        expect(page).to have_text("保存済み", wait: 10)
      end
      within_window(first) do
        ink_drag(0.1, 0.4, 0.6, 0.4, 1)
        expect(page).to have_text("保存を停止しました", wait: 10)
        expect(ink_alpha(0.3, 0.4)).to be > 0
        expect(page).to have_button("確認用PDFをダウンロード", disabled: false)
      end
      expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].length).to eq(2)
      within_window(second) do
        page.refresh
        expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
        expect(ink_alpha(0.3, 0.3)).to be > 0
        expect(ink_alpha(0.3, 0.4)).to eq(0)
      end
    end

    it "blocks input until restoration completes and preserves the loaded operation IDs" do
      AnswerDraft.create!(student: Student.find_by!(attendance_number: 1), assignment: @assignment,
        material_fingerprint: AnswerDraftContext.fingerprint(@assignment),
        page_data: [ { page_number: 1, operations: [ { id: 7, tool: "pen", color: "#000000", width: 1.2, points: [ [ 40, 240 ] ] } ] } ])
      install_browser_script(<<~JS)
        const nativeFetch=window.fetch.bind(window);
        window.fetch=(url,options)=>String(url).includes('/answer_draft') && options.method==='GET'
          ? new Promise(resolve=>window.releaseRestore=()=>resolve(nativeFetch(url,options))) : nativeFetch(url,options);
      JS
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_text("下書きの復元中…")
      expect(page).not_to have_css('[data-pdf-preview-target="ink"]', visible: true)
      expect(page).to have_button("確認用PDFをダウンロード", disabled: true)
      Timeout.timeout(10) { sleep 0.05 until page.evaluate_script("typeof window.releaseRestore === 'function'") }
      page.execute_script("window.releaseRestore()")
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      expect(ink_alpha(0.2, 0.2)).to be > 0
      ink_drag(0.3, 0.2, 0.4, 0.2, 1)
      expect(page).to have_text("保存済み", wait: 10)
      expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].map { |op| op["id"] }).to eq([ 7, 8 ])
    end

    it "does not overlay an old draft onto a replacement material" do
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      ink_drag(0.1, 0.2, 0.5, 0.2, 1)
      expect(page).to have_text("保存済み", wait: 10)
      original = AnswerDraft.find_by!(assignment: @assignment).attributes
      attach_preview("pdf_preview_three.pdf")
      page.refresh
      expect(page).to have_text("下書きを復元できません。ログイン状態・教材の変更を確認してください。", wait: 20)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      expect(page).to have_button("確認用PDFをダウンロード", disabled: true)
      expect(ink_alpha(0.3, 0.2, 1)).to eq(0)
      ink_drag(0.1, 0.2, 0.5, 0.2, 1)
      expect(ink_alpha(0.3, 0.2, 1)).to eq(0)
      expect(AnswerDraft.find_by!(assignment: @assignment).attributes).to eq(original)
    end

    it "recovers from an initial restore failure and enables PDF download only after successful restoration" do
      AnswerDraft.create!(student: Student.find_by!(attendance_number: 1), assignment: @assignment,
        material_fingerprint: AnswerDraftContext.fingerprint(@assignment),
        page_data: [ { page_number: 1, operations: [ { id: 1, tool: "pen", color: "#000000", width: 1.2, points: [ [ 40, 240 ] ] } ] } ])
      install_browser_script(<<~JS)
        const originalFetch=window.fetch.bind(window);let failed=false;
        window.fetch=(url,options)=>{
          if(String(url).includes('/answer_draft') && options.method==='GET' && !failed) {
            failed=true;return Promise.resolve(new Response('{}',{status:503,headers:{'Content-Type':'application/json'}}));
          }
          return originalFetch(url,options);
        };
      JS
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_text("下書きを復元できませんでした", wait: 20)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      state = page.evaluate_script("(()=>{const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller=pdf-preview]'),'pdf-preview');return {active:c.active,blocked:c.draft.blocked,disposed:!!c.draft.disposed,ready:!!c.draft.ready};})()")
      expect(state).to eq("active" => true, "blocked" => false, "disposed" => false, "ready" => false)
      expect(page).to have_button("確認用PDFをダウンロード", disabled: true)
      click_button "保存を再試行"
      expect(page).to have_text("保存済み", wait: 15)
      expect(page).to have_button("確認用PDFをダウンロード", disabled: false)
      expect(ink_alpha(0.2, 0.2)).to be > 0
    end

    it "allows finger scrolling of submitted quizzes while preventing new pen strokes and drafts" do
      Submission.create!(student: Student.find_by!(attendance_number: 1), assignment: @assignment, submitted_at: Time.current)
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_text("提出済みです。下書きは変更できません。", wait: 20)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      ink_drag(0.1, 0.1, 0.3, 0.1, 1)
      expect(ink_alpha(0.2, 0.1)).to eq(0)
      rect = find('[data-pdf-preview-target="ink"]').evaluate_script("this.getBoundingClientRect().toJSON()")
      x = (rect["x"] + rect["width"] * 0.8).round
      y = (rect["y"] + 180).round
      before = page.evaluate_script("scrollY")
      action = page.driver.browser.action
      action.add_pointer_input(:touch, "readonly-finger")
      action.move_to_location(x, y, device: "readonly-finger").pointer_down(:left, device: "readonly-finger")
        .move_to_location(x, y - 90, device: "readonly-finger").pointer_up(:left, device: "readonly-finger").perform
      Timeout.timeout(5) { sleep 0.05 until page.evaluate_script("scrollY") > before }
      expect(AnswerDraft.where(assignment: @assignment)).to be_empty
    end

    def login_draft_student
      visit student_login_path
      select "1年", from: "学年"
      select "1組", from: "クラス番号"
      select "1番", from: "出席番号"
      fill_in "学校コード", with: "PDFSYS"
      fill_in "パスワード", with: "password123"
      click_button "ログイン"
      expect(page).to have_current_path(student_assignments_path)
    end
  end

  def attach_preview(filename)
    @assignment.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files", filename)),
      filename: "preview.pdf", content_type: "application/pdf")
  end

  it "accepts a browser-generated pen pointer while finger drags scroll without adding ink" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
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
    bounds = find('[data-pdf-preview-target="ink"]').evaluate_script("this.getBoundingClientRect().toJSON()")
    y = (bounds["y"] + bounds["height"] * 0.1).round
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
