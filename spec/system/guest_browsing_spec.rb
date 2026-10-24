require "rails_helper"
require_relative "../support/demo_seed_fixture"
require "capybara/rspec"
require "tmpdir"
require "selenium-webdriver"

RSpec.describe "Fictional guest browsing", type: :system do
  include DemoSeedFixture
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
    expect(page).not_to have_button("この小テストを削除する")
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
  it "renders the isolated landing and updated sample views with large role choices" do
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    allow(Demo::Profile).to receive(:identity?).and_return(true)
    allow(Demo::Guest).to receive(:verify_target!) { Demo::Seed.new.verify_guest! }
    [ [ 320, 812 ], [ 1280, 900 ] ].each do |width, height|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: false)
      visit root_path
      expect(page).to have_link("QuickFlow", href: "https://13-231-93-159.sslip.io/")
      expect(page.find("h1 a")["aria-label"]).to eq("QuickFlow 通常のログイン選択へ")
      expect(page).to have_button("教師ゲストで閲覧")
      expect(page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")).to be(true)
      expect(page.evaluate_script("document.querySelector('.home-guest-options button').getBoundingClientRect().height")).to be >= 72
    end
    click_button "教師ゲストで閲覧"
    click_link "サンプルの小テスト"
    expect(page).to have_link("Excel出力")
    expect(page).to have_content("70点")
    find("header a.app-brand").click
    expect(page).to have_current_path(root_path)
    expect(page).to have_button("管理者ゲストで閲覧")
    click_button "生徒ゲストで閲覧"
    click_link "サンプルの小テスト"
    expect(page).to have_content("実際のAI実行結果ではありません")
    expect(page).not_to have_button("提出")
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
end
