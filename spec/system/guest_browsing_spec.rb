require "rails_helper"
require_relative "../support/demo_seed_fixture"
require "capybara/rspec"
require "tmpdir"
require "selenium-webdriver"
require_relative "../support/wordmark_checks"

RSpec.describe "Fictional guest browsing", type: :system do
  include DemoSeedFixture
  include WordmarkChecks
  around do |example|
    old = ENV["QUICKFLOW_GUEST_LOGIN"]
    ENV["QUICKFLOW_GUEST_LOGIN"] = "true"
    Rails.application.reload_routes!
    Dir.mktmpdir("guest-system-", Rails.root.join("tmp")) do |directory|
      @root = Pathname.new(directory)
      @root.join(".demo-isolation").write("b" * 32)
      example.run
    end
  ensure
    ENV["QUICKFLOW_GUEST_LOGIN"] = old
    Rails.application.reload_routes!
  end

  before do
    driven_by :rack_test
    allow_any_instance_of(Demo::Seed).to receive(:guard!) { |seed| seed.instance_variable_set(:@root, @root) }
    allow(ActiveStorage::Blob.services).to receive(:fetch).with("demo_seed")
      .and_return(ActiveStorage::Service::DiskService.new(root: @root.to_s, name: "demo_seed"))
    prepare_demo_seed_fixture
  end

  it "offers Japanese role choices, scoped business links, switching and logout" do
    visit "/"
    click_button "管理者ゲストで閲覧"
    expect(page).to have_content("架空データの閲覧専用ゲスト（管理者）")
    expect(page).to have_content("DEMO1")
    click_link "教師一覧"
    expect(page).to have_content("demo-teacher-1")
    expect(page).not_to have_content("demo-teacher-2")
    expect(page).not_to have_link("編集")
    click_button "教師ゲストに切り替える"
    expect(page).to have_content("配信済み小テスト")
    expect(page).not_to have_link("小テスト配信")
    click_link "サンプルの小テスト"
    expect(page).to have_content("成績一覧")
    expect(page).not_to have_link("名前を編集")
    expect(page).to have_button("この小テストを削除する", disabled: true)
    expect(page).to have_content("閲覧専用のため削除できません。")
    click_button "生徒ゲストに切り替える"
    expect(page).to have_content("架空データの閲覧専用ゲスト（生徒）")
    expect(page).not_to have_content("demo-teacher-2")
    click_link "サンプルの小テスト"
    expect(page).to have_content("実際のAI実行結果ではありません")
    expect(page).not_to have_button("提出")
    click_button "ゲストを終了"
    visit "/student/assignments"
    expect(page).to have_current_path("/student/login")
  end
  it "matches isolated role choices to normal login buttons and keeps the sample read-only" do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    allow(Demo::Profile).to receive(:identity?).and_return(true)
    allow(Demo::Guest).to receive(:verify_target!) { Demo::Seed.new.verify_guest! }
    [ [ 320, 812 ], [ 375, 812 ], [ 768, 1024 ], [ 1280, 900 ] ].each do |width, height|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: false)
      allow(Demo::Profile).to receive(:identity?).and_return(false)
      visit root_path
      # Compare the same available width even when only the normal page needs a scrollbar.
      page.execute_script("document.documentElement.style.overflowY = 'scroll'")
      expect_nanum_square_round_wordmark
      normal_wordmark = page.evaluate_script("(() => { const s=getComputedStyle(document.querySelector('.app-brand')); return ['fontFamily','fontSize','fontWeight','letterSpacing','color','lineHeight'].map(k=>s[k]); })()")
      normal_style = page.evaluate_script("(() => { const el=document.querySelector('.home-login-options .button'), s=getComputedStyle(el), r=el.getBoundingClientRect(); return ['fontFamily','fontSize','fontWeight','lineHeight','color','backgroundColor','borderRadius'].map(k=>s[k]).concat([r.width,r.height]); })()")
      allow(Demo::Profile).to receive(:identity?).and_return(true)
      visit root_path
      # Compare the same available width even when only the normal page needs a scrollbar.
      page.execute_script("document.documentElement.style.overflowY = 'scroll'")
      expect_nanum_square_round_wordmark
      expect(page.evaluate_script("(() => { const s=getComputedStyle(document.querySelector('.app-brand')); return ['fontFamily','fontSize','fontWeight','letterSpacing','color','lineHeight'].map(k=>s[k]); })()")).to eq(normal_wordmark)
      save_brand_evidence("guest-roles-#{width}")
      expect(page).not_to have_css(".home-description, .home-bubble")
      expect(page).not_to have_content("通常アカウントではログインできません。")
      expect(page).to have_link("QuickFlow", href: "https://13-231-93-159.sslip.io/")
      expect(page.find("h1 a")["aria-label"]).to eq("QuickFlow 通常のログイン選択へ")
      expect(page).to have_button("教師ゲストで閲覧")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
      role_styles = page.evaluate_script("Array.from(document.querySelectorAll('.home-guest-options button'), el => { const s=getComputedStyle(el), r=el.getBoundingClientRect(); return ['fontFamily','fontSize','fontWeight','lineHeight','color','backgroundColor','borderRadius'].map(k=>s[k]).concat([r.width,r.height]); })")
      expect(role_styles).to all(eq(normal_style))
      button = find_button("教師ゲストで閲覧")
      button.hover
      expect(button.evaluate_script("getComputedStyle(this).backgroundColor")).to eq("rgb(29, 78, 216)")
      find("body").send_keys(:tab, :tab, :tab)
      expect(page.evaluate_script("document.activeElement.textContent")).to eq("教師ゲストで閲覧")
      expect(button.evaluate_script("getComputedStyle(this).outlineStyle")).to eq("solid")
    end
    click_button "教師ゲストで閲覧"
    click_link "サンプルの小テスト"
    expect(page).to have_link("Excel出力")
    expect(page).to have_content("70点")
    expect(page).to have_button("この小テストを削除する", disabled: true)
    [ [ 320, 812 ], [ 1280, 900 ] ].each do |width, height|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: false)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
    end
    find("header a.app-brand").click
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("管理者ゲストで閲覧")
    click_button "生徒ゲストで閲覧"
    click_link "サンプルの小テスト"
    expect(page).to have_content("実際のAI実行結果ではありません")
    expect(page).not_to have_button("提出")
  end

  it "uses the NanumSquareRound ExtraBold white wordmark in every existing guest header" do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    allow(Demo::Profile).to receive(:identity?).and_return(true)
    allow(Demo::Guest).to receive(:verify_target!) { Demo::Seed.new.verify_guest! }
    %w[管理者 教師 生徒].each do |role|
      visit root_path
      click_button "#{role}ゲストで閲覧"
      expect(page).to have_content("架空データの閲覧専用ゲスト（#{role}）")
      [ 320, 375, 768, 1280 ].each do |width|
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: false)
        expect_nanum_square_round_wordmark
        expect(page.evaluate_script("getComputedStyle(document.querySelector('header')).backgroundColor")).to eq("rgb(37, 99, 235)")
        expect(page.evaluate_script("getComputedStyle(document.querySelector('header .app-brand')).color")).to eq("rgb(255, 255, 255)")
        expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
        expect(page).to have_link("QuickFlow", href: root_path)
        save_brand_evidence("guest-#{role}-header-#{width}")
      end
      find("header a.app-brand").click
      expect(page).to have_current_path(root_path)
    end
  end

  it "aligns the disabled guest delete button with Excel at desktop and narrow widths" do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    allow(Demo::Profile).to receive(:identity?).and_return(true)
    allow(Demo::Guest).to receive(:verify_target!) { Demo::Seed.new.verify_guest! }
    visit root_path
    click_button "教師ゲストで閲覧"
    click_link "サンプルの小テスト"
    expect(page).to have_link("Excel出力")
    expect(page).to have_button("この小テストを削除する", disabled: true)
    gaps = [ [ 320, 812 ], [ 1280, 900 ] ].map do |width, height|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: false)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
      page.evaluate_script("Math.abs(document.querySelector('.button-excel-export').getBoundingClientRect().right - document.querySelector('.assignment-delete-actions button').getBoundingClientRect().right)")
    end
    expect(gaps).to all(be <= 1)
  end

  it "does not restore a guest page through Chrome back navigation after logout" do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    visit "/"
    click_button "教師ゲストで閲覧"
    expect(page).to have_content("架空データの閲覧専用ゲスト（教師）")
    click_button "ゲストを終了"
    expect(page).to have_current_path("/login")
    page.go_back
    expect(page).not_to have_content("架空データの閲覧専用ゲスト")
    visit "/assignments"
    expect(page).to have_current_path("/login")
  end
  it "renders guest answer PDFs repeatedly through navigation, reload and resize without a native plug-in" do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    allow(Demo::Profile).to receive(:identity?).and_return(true)
    allow(Demo::Guest).to receive(:verify_target!) { Demo::Seed.new.verify_guest! }
    visit root_path
    [ [ "教師", 1280 ], [ "生徒", 320 ], [ "教師", 320 ], [ "生徒", 1280 ] ].each_with_index do |(role, width), index|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: false)
      expect(page.evaluate_script("innerWidth")).to eq(width)
      click_button "#{role}ゲストで閲覧"
      click_link "サンプルの小テスト"
      click_link "1番", exact: true if role == "教師"
      expect_guest_pdf_pixels
      if index.zero?
        expect(page).to have_css(".answer-pdf__pages") { |pages| pages.evaluate_script("this.offsetWidth > this.clientWidth") }
      end
      visit page.current_path
      expect_guest_pdf_pixels
      page.refresh
      expect_guest_pdf_pixels
      other_width = width == 320 ? 1280 : 320
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: other_width, height: 900, deviceScaleFactor: 1, mobile: false)
      expect_guest_pdf_pixels
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 900, deviceScaleFactor: 1, mobile: false)
      expect_guest_pdf_pixels
      if ENV["QF_PDF_EVIDENCE"]
        page.execute_script("document.querySelector('.answer-pdf').scrollIntoView({block: 'start'})")
        page.save_screenshot(File.join(ENV.fetch("QF_PDF_EVIDENCE"), "#{index}-#{width}.png"))
      end
      visit root_path
      page.go_back
      expect_guest_pdf_pixels
      find("header a.app-brand").click
      expect(page).to have_button("管理者ゲストで閲覧")
    end
    click_button "教師ゲストで閲覧"
    page.go_back
    expect(page).to have_button("生徒ゲストで閲覧")
  end

  [ :fetch, :worker ].each do |failure|
    it "shows actionable PDF reload guidance without an obsolete link on #{failure} failure" do
      driven_by :selenium, using: :headless_chrome, screen_size: [ 320, 812 ]
      allow(Demo::Profile).to receive(:identity?).and_return(true)
      allow(Demo::Guest).to receive(:verify_target!) { Demo::Seed.new.verify_guest! }
      visit root_path
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 320, height: 812, deviceScaleFactor: 1, mobile: false)
      expect(page.evaluate_script("innerWidth")).to eq(320)
      click_button "生徒ゲストで閲覧"
      page.driver.browser.execute_cdp("Network.enable")
      page.driver.browser.execute_cdp("Network.setCacheDisabled", cacheDisabled: true)
      if failure == :fetch
        page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [ "*/student/assignments/*/answer*" ])
      else
        # Network blocking on the page target does not reliably intercept a dedicated worker.
        worker_failure = <<~JS
          window.qfOriginalWorker=window.Worker;
          window.Worker=class extends window.Worker {
            constructor(url,options) {
              if(String(url).includes('/pdf.worker.min.mjs')) throw new DOMException('Synthetic worker creation failure','SecurityError');
              super(url,options);
            }
          };
        JS
        worker_script = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: worker_failure).fetch("identifier")
        page.execute_script(worker_failure)
      end
      click_link "サンプルの小テスト"
      expect(page).to have_css("[data-answer-pdf-target='status']", text: "答案PDFを表示できませんでした。")
      expect(page).not_to have_css('.answer-pdf a, .answer-pdf [target="_blank"]', visible: :all)
      expect(page.html).not_to include("PDFを別タブで開く", "下のリンク")
      expect(page).to have_text("時間をおいて画面を再読み込みしてください。")
      expect(page).not_to have_css("canvas[data-rendered='true']")
      page.save_screenshot(File.join(ENV.fetch("QF_PDF_EVIDENCE"), "error-#{failure}-320.png")) if ENV["QF_PDF_EVIDENCE"]
      page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
      if worker_script
        page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: worker_script)
        worker_script = nil
        page.execute_script("window.Worker=window.qfOriginalWorker")
      end
      page.refresh
      expect_guest_pdf_pixels
      expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
    ensure
      if worker_script
        page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: worker_script)
        page.execute_script("window.Worker=window.qfOriginalWorker")
      end
      page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
      page.driver.browser.execute_cdp("Network.setCacheDisabled", cacheDisabled: false)
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
      page.current_window.resize_to(1280, 900)
    end
  end

  def expect_guest_pdf_pixels
    expect(page).to have_css(".answer-pdf")
    # Exercise non-overlay scrollbar geometry on macOS as well as Linux CI.
    page.execute_script(<<~JS)
      if (!document.getElementById('guest-pdf-scrollbar-fixture')) {
        const style = document.createElement('style');
        style.id = 'guest-pdf-scrollbar-fixture';
        style.textContent = '.answer-pdf__pages::-webkit-scrollbar { width: 16px; height: 16px; }';
        document.head.append(style);
      }
    JS
    expect(page).to have_css("[data-answer-pdf-target='status']", text: "答案PDFを表示しました")
    expect(page).to have_css("canvas[data-rendered='true']")
    expect(page).not_to have_css("iframe.teacher-answer-pdf")
    # ResizeObserver may replace a previously rendered canvas between queries.
    # Wait for current-size pixels, rather than sampling once during that transition.
    expect(page).to have_css(".answer-pdf canvas[data-rendered='true']", count: 1) do |canvas|
      canvas.evaluate_script(<<~JS)
        (() => {
          if (!this.isConnected || this.dataset.rendered !== 'true' || !this.width || !this.height) return false;
          const ratio = Math.min(devicePixelRatio || 1, 2);
          // Rendering can precede the vertical scrollbar appearing; CSS scales the raster.
          const minWidth = Math.min(this.parentElement.clientWidth, 1200) * ratio;
          const maxWidth = Math.min(this.parentElement.offsetWidth, 1200) * ratio;
          if (this.width < Math.floor(minWidth) - 1 || this.width > Math.ceil(maxWidth) + 1) return false;
          const pixels = this.getContext('2d').getImageData(0,0,this.width,this.height).data;
          let ink = 0;
          for (let i=0; i<pixels.length; i+=16) {
            if (pixels[i+3] > 0 && pixels[i] < 200 && pixels[i+1] < 200 && pixels[i+2] < 200) ink++;
          }
          return ink > 50;
        })()
      JS
    end
    expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
    expect(page).to have_content("70点")
    expect(page).not_to have_button("提出")
    expect(page).not_to have_css('.answer-pdf a, .answer-pdf [target="_blank"]', visible: :all)
    expect(page.html).not_to include("PDFを別タブで開く")
  end
end
