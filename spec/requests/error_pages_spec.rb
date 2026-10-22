require "rails_helper"

RSpec.describe "Static error pages", type: :request do
  around do |example|
    original = Rails.application.env_config.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
    Rails.application.env_config["action_dispatch.show_exceptions"] = :all
    Rails.application.env_config["action_dispatch.show_detailed_exceptions"] = false
    example.run
  ensure
    Rails.application.env_config.merge!(original)
  end

  { 400 => "リクエストを処理できません", 404 => "ページが見つかりません",
    406 => "お使いのブラウザは対応していません", 422 => "操作を完了できません", 500 => "処理中に問題が発生しました" }.each do |status, heading|
    it "preserves status and serves the standalone Japanese #{status} page" do
      if status == 400
        post login_path, params: { private_parameter: "private parameter details" }
      elsif status == 406
        get root_path, headers: { "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.212 Safari/537.36" }
      elsif status == 422
        old_csrf = ActionController::Base.allow_forgery_protection
        ActionController::Base.allow_forgery_protection = true
        post login_path, params: { session: { user_id: "private-user", password: "private-password" }, authenticity_token: "invalid" }
      elsif status == 500
        allow_any_instance_of(HomeController).to receive(:index).and_raise(StandardError, "private exception details")
        get root_path
      else
        get "/missing-issue90-page"
      end

      expect(response.status).to eq(status)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to eq(Rails.public_path.join(status == 406 ? "406-unsupported-browser.html" : "#{status}.html").read)
      expect(response.body).not_to include("private exception details", "private parameter details", "private-user", "private-password", "StandardError", "RoutingError", "InvalidAuthenticityToken")

      document = Nokogiri::HTML(response.body)
      expect(document.at_css("html")["lang"]).to eq("ja")
      expect(document.at_css("title").text).to include(status.to_s, heading, "QuickFlow")
      expect(document.at_css("h1").text).to eq(heading)
      expect(document.at_css(".app-brand").text).to eq("QuickFlow")
      expect(document.at_css("meta[name='viewport']")["content"]).to include("width=device-width")
      expect(document.css("a").map { |link| [ link.text, link["href"] ] }).to eq([ [ "トップページへ", "/" ] ])
      expect(document.css("script, link, img, iframe, form, [src], [onclick], meta[http-equiv='refresh']")).to be_empty
      expect(document.at_css("style").text).not_to match(/url\s*\(|@import/i)
    ensure
      ActionController::Base.allow_forgery_protection = old_csrf if status == 422
    end
  end

  it "keeps a HEAD response at 404 without a body" do
    head "/missing-issue90-page"

    expect(response).to have_http_status(:not_found)
    expect(response.body).to be_empty
  end
end
