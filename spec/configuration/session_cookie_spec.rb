require "spec_helper"
require "open3"
require "json"
require "uri"

RSpec.describe "Session cookie configuration" do
  def boot(environment)
    # CI supplies an endpoint without a database; every probe must use the test DB.
    database_url = URI(ENV.fetch("DATABASE_URL", "postgresql:///quickflow_test"))
    database_url.path = "/quickflow_test" if [ "", "/" ].include?(database_url.path)

    script = <<~'SCRIPT'
      require "json"
      require "rack/mock"
      app = Rails.application
      app.routes.prepend do
        get "/session-cookie-probe", to: ->(env) {
          Rack::Request.new(env).session[:probe] = "synthetic"
          [200, { "content-type" => "text/plain" }, ["ok"]]
        }
      end
      app.reload_routes!
      result = { options: app.config.session_options, force_ssl: app.config.force_ssl,
        assume_ssl: app.config.assume_ssl }
      ["https", "http"].each do |scheme|
        response = Rack::MockRequest.new(app).get("#{scheme}://localhost/session-cookie-probe", "HTTP_HOST" => "localhost")
        result[scheme] = { status: response.status, cookie: response["set-cookie"] }
      end
      puts "SESSION_RESULT=#{JSON.generate(result)}"
    SCRIPT
    output, error, status = Open3.capture3({ "RAILS_ENV" => environment, "SECRET_KEY_BASE" => "a" * 128,
      "DATABASE_URL" => database_url.to_s },
      "bundle", "exec", "rails", "runner", script)
    expect(status.success?).to be(true), error + output
    JSON.parse(output.lines.find { |line| line.start_with?("SESSION_RESULT=") }.delete_prefix("SESSION_RESULT="))
  end

  it "issues the original production cookie with Secure, HttpOnly, Lax and the root path" do
    result = boot("production")
    expect(result.fetch("options")).to include("key" => "_quickflow_session", "secure" => true,
      "httponly" => true, "same_site" => "lax", "path" => "/")
    expect(result.fetch("force_ssl")).to be_falsey
    expect(result.fetch("assume_ssl")).to be_falsey
    expect(result.dig("https", "status")).to eq(200)
    cookie = Array(result.dig("https", "cookie")).join(";")
    expect(cookie).to start_with("_quickflow_session=")
    expect(cookie).to include("secure", "httponly", "samesite=lax", "path=/")
    # A missing proxy scheme must not be mistaken for successful HTTPS session issuance.
    expect(result.dig("http", "cookie")).to be_nil
  end

  %w[development test].each do |environment|
    it "keeps #{environment} HTTP session issuance available" do
      result = boot(environment)
      expect(result.dig("http", "status")).to eq(200)
      cookie = Array(result.dig("http", "cookie")).join(";")
      expect(cookie).to start_with("_quickflow_session=")
      expect(cookie).to include("httponly", "samesite=lax", "path=/")
      expect(cookie).not_to match(/;\s*secure/i)
    end
  end
end
