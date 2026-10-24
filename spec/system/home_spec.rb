require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"

RSpec.describe "Home login choices", type: :system do
  before do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
  end

  it "enlarges only the home logo while retaining existing brand typography" do
    [ [ 1280, 900 ], [ 375, 812 ] ].each do |width, height|
      page.current_window.resize_to(width, height)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: height, deviceScaleFactor: 1, mobile: false)
      expect(page.evaluate_script("window.innerWidth")).to eq(width)
      styles = [ root_path, login_path, student_login_path ].map do |path|
        visit path
        page.evaluate_script(<<~JS)
          (() => {
            const style = getComputedStyle(document.querySelector('.app-brand'));
            return ['fontFamily', 'fontWeight', 'color']
              .map(property => style[property]);
          })()
        JS
      end
      expect(styles.uniq.length).to eq(1)
      sizes = [ root_path, login_path, student_login_path ].map do |path|
        visit path
        page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('.app-brand')).fontSize)")
      end
      expect(sizes.first).to be > sizes[1]
      expect(sizes.first).to be > sizes[2]
    end
  end

  it "keeps the logo still and places the two explanation rows below it" do
    visit root_path
    expect(page).to have_css("h1[aria-label='QuickFlow']", text: "QuickFlow")
    expect(page).not_to have_css(".home-letter, .home-bubble")
    expect(page.all(".home-description p").size).to eq(2)
    expect(page.evaluate_script("getComputedStyle(document.querySelector('.home-wordmark')).animationName")).to eq("none")
    expect(page.evaluate_script("document.querySelector('.home-description').getBoundingClientRect().top >= document.querySelector('.home-wordmark').getBoundingClientRect().bottom")).to be(true)
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
