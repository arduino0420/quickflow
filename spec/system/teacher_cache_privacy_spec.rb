require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"
require_relative "../support/ai_grading_context"

RSpec.describe "Teacher private page history", type: :system do
  include_context "AI grading records"

  let(:teacher) { Teacher.create!(school: school, user_id: "private-page-teacher", password: "Matsue2026") }

  before do
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
  end

  it "does not restore grades from Turbo history after logout" do
    submission
    visit login_path
    fill_in "ユーザーID", with: teacher.user_id
    fill_in "パスワード", with: "Matsue2026"
    click_button "ログイン"
    expect(page).to have_current_path(assignments_path)
    visit assignment_path(assignment)
    expect(page).to have_content("成績一覧")
    visit assignments_path
    click_button "ログアウト"
    expect(page).to have_content("教師ログイン")

    page.go_back

    expect(page).to have_content("教師ログイン")
    expect(page).not_to have_content("成績一覧")
  end
end
