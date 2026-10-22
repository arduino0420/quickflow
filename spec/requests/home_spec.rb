require "rails_helper"

RSpec.describe "Home", type: :request do
  it "presents a public Japanese introduction with exactly two login choices" do
    get root_path

    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("html")["lang"]).to eq("ja")
    expect(document.at_css("h1").text).to eq("QuickFlow")
    expect(document.text).to include("教師の負担を減らし", "生徒の学び", "AI採点", "自動保存", "Excel出力")
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
