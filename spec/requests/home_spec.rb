require "rails_helper"

RSpec.describe "Home", type: :request do
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
end
