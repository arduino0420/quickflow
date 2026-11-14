require "spec_helper"
require "yaml"
require "erb"

RSpec.describe "Docker development configuration" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:development) { YAML.safe_load(File.read(File.join(root, "compose.development.yaml"))) }
  let(:production) { YAML.safe_load(File.read(File.join(root, "compose.yaml"))) }

  it "opts into development without changing the default production topology" do
    expect(production.fetch("services").fetch("web").fetch("environment").fetch("RAILS_ENV")).to eq("production")
    expect(production.fetch("services").fetch("web").fetch("volumes")).to eq([ "storage:/rails/storage" ])
    expect(development.fetch("services").keys.sort).to eq(%w[caddy db web])
    web = development.fetch("services").fetch("web")
    expect(web.fetch("build").fetch("target")).to eq("development")
    expect(web.fetch("environment").fetch("RAILS_ENV")).to eq("development")
    expect(web.fetch("environment").fetch("BUNDLE_IGNORE_CONFIG")).to eq("1")
    expect(web.fetch("volumes")).to include(".:/rails", "storage:/rails/storage")
    expect(web.fetch("tmpfs").join(" ")).to include("/rails/public/assets", "/rails/vendor/qpdf")
    expect(web).not_to have_key("env_file")
  end

  it "keeps development data and the database port private to its Compose project" do
    expect(development.fetch("volumes").values).to all(be_nil)
    expect(development.fetch("services").fetch("db")).not_to have_key("ports")
    expect(development.fetch("services").fetch("caddy").fetch("ports")).to eq([ "127.0.0.1:${QF_DEV_PORT:-13000}:80" ])
    wrapper = File.read(File.join(root, "bin/dev-docker"))
    expect(wrapper).to include("--context desktop-linux", "--env-file /dev/null", "-f compose.development.yaml")
  end

  it "provides explicit local connection details to development and test databases" do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("QUICKFLOW_DOCKER_DEVELOPMENT").and_return("1")
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("PGHOST").and_return("db")
    allow(ENV).to receive(:fetch).with("PGUSER").and_return("quickflow")
    allow(ENV).to receive(:fetch).with("PGPASSWORD").and_return("quickflow-local-only")
    config = YAML.safe_load(ERB.new(File.read(File.join(root, "config/database.yml"))).result, aliases: true)
    expect(config.fetch("test")).to include("host" => "db", "username" => "quickflow", "database" => "quickflow_test")
    expect(config.fetch("development").fetch("primary")).to include("host" => "db", "database" => "quickflow_development")
    expect(config.fetch("development").fetch("queue")).to include("host" => "db", "database" => "quickflow_development_queue")
  end

  it "does not opt AWS into development implicitly" do
    expect(File.exist?(File.join(root, "compose.override.yaml"))).to be(false)
    dockerfile = File.read(File.join(root, "Dockerfile"))
    expect(dockerfile.scan(/^FROM .*$/).last).to eq("FROM base")
  end
end
