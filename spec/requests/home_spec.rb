require "rails_helper"

RSpec.describe "Home", type: :request do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("QUICKFLOW_GUEST_ENTRY_URL").and_return(nil)
  end

  it "presents the requested logo and ordered login choices with guest safely disabled" do
    get root_path

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("html")["lang"]).to eq("ja")
    expect(document.at_css("h1").text).to eq("QuickFlow")
    expect(document.text).to include("中学校数学の小テストを通じて、教師の負担を減らし、生徒の学びを支えるアプリです。",
      "教師はPDF教材の配信・AI採点・得点集計・Excel出力を、生徒はPDFへの直接手書き・自動保存・提出・結果確認を行えます。")
    choices = document.css(".home-login-options > *")
    expect(choices.map(&:text)).to eq([ "教師としてログインする", "生徒としてログインする", "ゲストとしてログインする" ])
    expect(choices.all? { |choice| choice["class"].split.include?("button-secondary") }).to be(true)
    guest = choices.last
    expect(guest.name).to eq("button")
    expect(guest.key?("disabled")).to be(true)
    expect(guest["aria-describedby"]).to eq("guest-unavailable")
    expect(document.at_css("#guest-unavailable").text).to eq("ゲスト体験は準備中です。")
    expect(document.css("a").map { |link| [ link.text, link["href"] ] }).to eq([
      [ "教師としてログインする", login_path ],
      [ "生徒としてログインする", student_login_path ]
    ])
    expect(document.css("form, img")).to be_empty
  end

  it "keeps all three existing login pages directly accessible" do
    [ login_path, student_login_path, admin_login_path ].each do |path|
      get path
      expect(response).to have_http_status(:ok)
    end
  end

  it "links to the configured HTTPS guest host without enabling production guest login" do
    destination = "https://qfd-0123456789abcdef.www.example.com/"
    allow(ENV).to receive(:[]).with("QUICKFLOW_GUEST_ENTRY_URL").and_return(destination)

    get root_path

    document = Nokogiri::HTML(response.body)
    guest = document.css(".home-login-options > *").last
    expect(guest.name).to eq("a")
    expect(guest["href"]).to eq(destination)
    expect(guest["aria-describedby"]).to eq("guest-available")
    expect(document.text).to include("架空データの閲覧専用ゲスト体験へ移動します。")
    expect(document.css("form")).to be_empty
    post "/guest/admin"
    expect(response).to have_http_status(:not_found)
  end

  it "keeps the entry disabled for destinations outside the dedicated HTTPS host boundary" do
    [
      "http://qfd-0123456789abcdef.www.example.com/",
      "https://qfd-0123456789abcdef.other.example/",
      "https://www.example.com/", "javascript:alert(1)", "//other.example/",
      "https://user:password@qfd-0123456789abcdef.www.example.com/",
      "https://qfd-0123456789abcdef.www.example.com:18443/",
      "https://qfd-0123456789abcdef.www.example.com/login",
      "https://qfd-0123456789abcdef.www.example.com/?next=elsewhere",
      "https://qfd-0123456789abcdef.www.example.com/#section", "not a URL"
    ].each do |destination|
      allow(ENV).to receive(:[]).with("QUICKFLOW_GUEST_ENTRY_URL").and_return(destination)
      get root_path
      guest = Nokogiri::HTML(response.body).css(".home-login-options > *").last
      expect(guest.name).to eq("button")
      expect(guest.key?("disabled")).to be(true)
    end
  end
end
