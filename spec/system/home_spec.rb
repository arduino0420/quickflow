require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"

RSpec.describe "Home login choices", type: :system do
  before do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
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

  it "keeps both choices visible without horizontal overflow on mobile and tablet" do
    [ [ 375, 812 ], [ 768, 1024 ] ].each do |width, height|
      page.current_window.resize_to(width, height)
      visit root_path
      expect(page).to have_link("教師としてログインする", visible: true)
      expect(page).to have_link("生徒としてログインする", visible: true)
      expect(page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")).to be(true)
      expect(page.evaluate_script("document.querySelector('.home-login-options').getBoundingClientRect().bottom <= window.innerHeight")).to be(true)
    end
  end
end
