require "spec_helper"
require "yaml"
require "erb"
require "open3"
require "tmpdir"
require "digest"

RSpec.describe "Docker development configuration" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:compose) { YAML.safe_load(File.read(File.join(root, "compose.yaml"))) }

  it "shares three services and defaults to a read-only production image" do
    expect(Dir.glob(File.join(root, "compose*.y{a,}ml"))).to eq([ File.join(root, "compose.yaml") ])
    expect(compose.fetch("services").keys.sort).to eq(%w[caddy db web])
    web = compose.fetch("services").fetch("web")
    expect(web.fetch("environment").fetch("RAILS_ENV")).to eq("${QF_RAILS_ENV:-production}")
    expect(web.fetch("build").fetch("target")).to eq("${QF_BUILD_TARGET:-production}")
    expect(web.fetch("read_only")).to eq("${QF_READ_ONLY:-true}")
    expect(web.fetch("volumes")).to eq([ "storage:/rails/storage", "runtime_tmp:/rails/tmp", "runtime_log:/rails/log" ])
    expect(web.fetch("entrypoint")).to eq([ "/usr/local/bin/quickflow-compose-entrypoint" ])
  end

  it "syncs portable source only when Watch is running" do
    rules = compose.fetch("services").fetch("web").fetch("develop").fetch("watch")
    expect(rules.map { |rule| rule.fetch("path") }).to eq(%w[./app ./lib ./public ./config])
    expect(rules).to all(include("initial_sync" => true))
    expect(rules.find { |rule| rule["path"] == "./public" }.fetch("ignore")).to include("assets/")
    expect(rules.find { |rule| rule["path"] == "./config" }.fetch("ignore")).to include("*.key", "credentials/")
    expect(rules.find { |rule| rule["path"] == "./config" }.fetch("action")).to eq("sync+restart")
    expect(compose.fetch("services").fetch("db")).not_to have_key("ports")
  end

  it "preserves this folder's development data and discards inherited production settings" do
    Dir.mktmpdir do |directory|
      docker = File.join(directory, "docker")
      File.write(docker, %q(#!/bin/sh
printf '%s\n' "$QF_DB_VOLUME" "$QF_STORAGE_VOLUME" "$QF_APP_ENV_FILE" "$QF_HTTP_BIND" "$QF_CADDY_EXTRA_CONFIG" "$@"
))
      File.chmod(0o755, docker)
      git = File.join(directory, "git")
      File.write(git, "#!/bin/sh\nprintf '%s\\n' test-revision\n")
      File.chmod(0o755, git)
      env = { "PATH" => "#{directory}:#{ENV.fetch('PATH')}", "QF_DB_VOLUME" => "production-data", "QF_APP_ENV_FILE" => "/production.env", "QF_DEV_PORT" => "13001" }
      output, error, status = Open3.capture3(env, File.join(root, "bin/dev-docker"), "config")
      expect(status.success?).to be(true), error
      project = "quickflow-dev-#{Digest::SHA256.hexdigest(File.realpath(root))[0, 10]}"
      expect(output.lines.map(&:strip)).to eq([ "#{project}_db_data", "#{project}_storage", "/dev/null", "127.0.0.1:13001", "/dev/null",
        "--context", "desktop-linux", "compose", "--env-file", "/dev/null", "--project-name", project, "-f", "compose.yaml", "config" ])
    end
  end

  it "rejects a runtime that differs from the built image before executing a command" do
    Dir.mktmpdir do |directory|
      cat = File.join(directory, "cat")
      File.write(cat, "#!/bin/sh\nprintf '%s' \"$TEST_IMAGE_RUNTIME\"\n")
      File.chmod(0o755, cat)
      env = { "PATH" => "#{directory}:#{ENV.fetch('PATH')}", "TEST_IMAGE_RUNTIME" => "production", "RAILS_ENV" => "development", "QUICKFLOW_DOCKER_DEVELOPMENT" => "1" }
      output, error, status = Open3.capture3(env, File.join(root, "bin/docker-compose-entrypoint"), "/bin/echo", "executed")
      expect(status.success?).to be(false)
      expect(output).to be_empty
      expect(error).to include("Refusing mismatched")
      env.merge!("RAILS_ENV" => "production", "QUICKFLOW_DOCKER_DEVELOPMENT" => "0")
      output, error, status = Open3.capture3(env, File.join(root, "bin/docker-compose-entrypoint"), "/bin/echo", "executed")
      expect(status.success?).to be(true), error
      expect(output).to eq("executed\n")
    end
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
    expect(dockerfile.scan(/^FROM .*$/).last).to eq("FROM base AS production")
  end
end
