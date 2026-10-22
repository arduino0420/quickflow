require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"

RSpec.describe "Admin teacher list layout", type: :system do
  before do
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    school = School.create!(school_code: "TEACHERLAYOUT")
    @teacher = Teacher.create!(school: school, user_id: "teacher-layout", password: "teacher-password")
    Admin.create!(school: school, user_id: "admin-layout", password: "admin-password")
    visit admin_login_path
    fill_in "管理者ID", with: "admin-layout"
    fill_in "パスワード", with: "admin-password"
    click_button "ログイン"
    click_link "教師一覧"
  end

  it "keeps both actions on one line without page overflow at phone, tablet and desktop widths" do
    expect(page).to have_css(".admin-teacher-row-actions .button", count: 2)

    [ 390, 768, 1280 ].each do |width|
      page.current_window.resize_to(width, 900)
      layout = page.evaluate_script(<<~JS)
        (() => {
          const buttons = [...document.querySelectorAll('.admin-teacher-row-actions .button')];
          const rects = buttons.map(button => button.getBoundingClientRect());
          return {
            viewport: window.innerWidth,
            pageWidth: document.documentElement.scrollWidth,
            tops: rects.map(rect => rect.top),
            heights: rects.map(rect => rect.height),
            gap: rects[1].left - rects[0].right,
            right: rects[1].right,
            whiteSpace: buttons.map(button => getComputedStyle(button).whiteSpace)
          };
        })()
      JS

      expect(layout["tops"][0]).to be_within(1).of(layout["tops"][1]), "actions are not aligned at #{width}px"
      expect(layout["heights"][0]).to be_within(1).of(layout["heights"][1]), "button heights differ at #{width}px"
      expect(layout["gap"]).to be_between(1, 16), "button spacing is incorrect at #{width}px"
      expect(layout["whiteSpace"]).to eq([ "nowrap", "nowrap" ])
      expect(layout["right"]).to be <= layout["viewport"]
      expect(layout["pageWidth"]).to be <= layout["viewport"]
    end

    within(".admin-teacher-list tbody tr") do
      expect(page).to have_link("編集", href: edit_admin_teacher_path(@teacher))
      expect(page).to have_link("パスワード再設定", href: edit_admin_teacher_path(@teacher, anchor: "password-reset"))
      find('td[data-label="教師ID"]').click
    end
    expect(page).to have_current_path(edit_admin_teacher_path(@teacher))
    expect(page).to have_content("教師アカウントの編集")

    click_link "教師一覧へ戻る"
    click_link "パスワード再設定"
    expect(page).to have_current_path(edit_admin_teacher_path(@teacher))
    expect(page.evaluate_script("window.location.hash")).to eq("#password-reset")
    expect(page).to have_field("新しいパスワード")
  end
end
