require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"
require_relative "../support/wordmark_checks"

RSpec.describe "Home login choices", type: :system do
  include WordmarkChecks

  before do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
  end

  it "uses the local NanumSquareRound ExtraBold font for home and every login wordmark at their own sizes" do
    [ [ 320, 812 ], [ 375, 812 ], [ 768, 1024 ], [ 1280, 900 ] ].each do |width, height|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: height, deviceScaleFactor: 1, mobile: false)
      sizes = [ root_path, login_path, student_login_path, admin_login_path ].map do |path|
        visit path
        expect_nanum_square_round_wordmark
        expect(page.evaluate_script("getComputedStyle(document.body).fontFamily")).not_to include("NanumSquareRound")
        expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
        save_brand_evidence("#{path.tr('/', '-')}-#{width}")
        page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('.app-brand')).fontSize)")
      end
      expect(sizes.first).to be > sizes[1..].max
    end
  end

  it "keeps wordmarks readable when the local font cannot load" do
    page.driver.browser.execute_cdp("Network.enable")
    page.driver.browser.execute_cdp("Network.setCacheDisabled", cacheDisabled: true)
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [ "*/fonts/nanum-square-round/*" ])
    [ 320, 1280 ].each do |width|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: 900, deviceScaleFactor: 1, mobile: false)
      [ root_path, login_path, student_login_path, admin_login_path, "/404.html" ].each do |path|
        visit path
        expect(page).to have_css(".app-brand", text: "QuickFlow", visible: true)
        loaded = page.evaluate_async_script(<<~JS)
          const done = arguments[arguments.length - 1];
          document.fonts.ready.then(() => done([...document.fonts].some(face => face.status === 'loaded')));
        JS
        expect(loaded).to be(false)
        page.driver.browser.execute_cdp("DOM.enable")
        page.driver.browser.execute_cdp("CSS.enable")
        root = page.driver.browser.execute_cdp("DOM.getDocument").fetch("root").fetch("nodeId")
        node = page.driver.browser.execute_cdp("DOM.querySelector", nodeId: root, selector: ".app-brand").fetch("nodeId")
        fonts = page.driver.browser.execute_cdp("CSS.getPlatformFontsForNode", nodeId: node).fetch("fonts")
        expect(fonts).not_to be_empty
        expect(fonts).to all(include("isCustomFont" => false))
        expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
        save_brand_evidence("font-fallback-#{path.tr('/', '-')}-#{width}")
      end
    end
  ensure
    page.driver.browser.execute_cdp("Network.setBlockedURLs", urls: [])
    page.driver.browser.execute_cdp("Network.setCacheDisabled", cacheDisabled: false)
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end

  it "keeps the logo still and puts the choices directly after the introduction" do
    visit root_path
    expect(page).to have_css("h1[aria-label='QuickFlow']", text: "QuickFlow")
    expect(page).not_to have_css(".home-description, .home-letter, .home-bubble")
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.home-wordmark')).animationName")).to eq("none")
    expect(page.evaluate_script("document.querySelector('.home-intro').nextElementSibling.matches('.home-login-options')")).to be(true)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.home-wordmark')).animationName")).to eq("none")
  ensure
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
  end

  it "distinguishes enabled, hovered, keyboard-focused and disabled choices" do
    visit root_path
    teacher = find_link("教師としてログインする")
    expect(teacher.evaluate_script("getComputedStyle(this).backgroundColor")).to eq("rgb(37, 99, 235)")
    expect(teacher.evaluate_script("getComputedStyle(this).color")).to eq("rgb(255, 255, 255)")
    teacher.hover
    expect(teacher.evaluate_script("getComputedStyle(this).backgroundColor")).to eq("rgb(29, 78, 216)")
    find("body").send_keys(:tab)
    expect(page.evaluate_script("document.activeElement.textContent")).to eq("教師としてログインする")
    expect(teacher.evaluate_script("getComputedStyle(this).outlineStyle")).to eq("solid")
    disabled = find_button("ゲストとしてログインする", disabled: true)
    expect(disabled.evaluate_script("getComputedStyle(this).backgroundColor")).to eq("rgb(226, 232, 240)")
    disabled.hover
    expect(disabled.evaluate_script("getComputedStyle(this).backgroundColor")).to eq("rgb(226, 232, 240)")
  end

  it "supports keyboard navigation and both login destinations" do
    visit root_path
    page.find("body").send_keys(:tab)
    expect(page.evaluate_script("document.activeElement.textContent")).to eq("教師としてログインする")
    page.driver.browser.switch_to.active_element.send_keys(:enter)
    expect(page).to have_current_path(login_path)
    expect(page).to have_content("教師ログイン")

    visit root_path
    click_link "生徒としてログインする"
    expect(page).to have_current_path(student_login_path)
    expect(page).to have_content("生徒ログイン")
  end

  it "keeps all three choices visible without horizontal overflow on mobile and tablet" do
    [ [ 320, 812 ], [ 375, 812 ], [ 768, 1024 ], [ 1280, 900 ] ].each do |width, height|
      page.current_window.resize_to(width, height)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: height, deviceScaleFactor: 1, mobile: false)
      expect(page.evaluate_script("window.innerWidth")).to eq(width)
      visit root_path
      expect(page).to have_link("教師としてログインする", visible: true)
      expect(page).to have_link("生徒としてログインする", visible: true)
      expect(page).to have_button("ゲストとしてログインする", disabled: true, visible: true)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      expect(page.evaluate_script("document.querySelector('.home-login-options').getBoundingClientRect().bottom <= window.innerHeight")).to be(true)
    end
  end

  it "shows the configured guest link without overflow and makes it keyboard accessible" do
    destination = "https://qfd-0123456789abcdef.127.0.0.1/"
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("QUICKFLOW_GUEST_ENTRY_URL").and_return(destination)

    [ [ 320, 812 ], [ 1280, 900 ] ].each do |width, height|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: height, deviceScaleFactor: 1, mobile: false)
      visit root_path
      expect(page).to have_link("ゲストとしてログインする", href: destination, visible: true)
      expect(page).not_to have_content("架空データの閲覧専用ゲスト体験へ移動します。")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      page.find("body").send_keys(:tab, :tab, :tab)
      expect(page.evaluate_script("document.activeElement.textContent")).to eq("ゲストとしてログインする")
    end
  end
end
