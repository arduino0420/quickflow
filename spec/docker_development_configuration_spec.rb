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

  it "does not opt AWS into development implicitly" do
    expect(File.exist?(File.join(root, "compose.override.yaml"))).to be(false)
    dockerfile = File.read(File.join(root, "Dockerfile"))
    expect(dockerfile.scan(/^FROM .*$/).last).to eq("FROM base")
  end
end
