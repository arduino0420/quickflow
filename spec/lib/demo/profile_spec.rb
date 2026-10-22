require "spec_helper"
require "tmpdir"
require_relative "../../../lib/demo/profile"
require_relative "../../../lib/demo/transport_boundary"
require_relative "../../../lib/demo/reject_jobs_adapter"

RSpec.describe Demo::Profile do
  around do |example|
    original = ENV.to_h
    ENV.replace("PATH" => original.fetch("PATH"))
    Dir.mktmpdir("demo-profile-") do |directory|
      @declaration = File.join(File.realpath(directory), "target.json")
      @token = "a" * 32
      @target = { "version" => 1, "isolation_id" => @token, "database" => "quickflow_demo_#{'a' * 16}",
        "runtime_role" => "qfd_runtime_#{'a' * 16}", "provision_role" => "qfd_provision_#{'a' * 16}",
        "host" => "127.0.0.1", "port" => 55445, "https_port" => 55446,
        "allowed_host" => "qfd-#{'a' * 16}.localhost", "data_directory" => File.expand_path("../../../tmp/production-demo-pg-#{@token}", __dir__), "system_identifier" => "12345",
        "storage_root" => File.expand_path("../../../tmp/production-demo-#{@token}", __dir__) }
      File.write(@declaration, JSON.generate(@target))
      example.run
    end
  ensure
    ENV.replace(original)
  end

  def configure_runtime
    ENV.update("RAILS_ENV" => "production", "QUICKFLOW_DEMO_PROFILE" => "production",
      "QUICKFLOW_DEMO_TARGET" => @declaration, "QUICKFLOW_DEMO_SESSION_SECRET" => "b" * 128,
      "QUICKFLOW_DEMO_DATABASE_URL" => "postgresql://#{@target.fetch('runtime_role')}:#{'c' * 64}@127.0.0.1:55445/#{@target.fetch('database')}")
  end

  it "leaves the ordinary OFF environment untouched" do
    ENV["DATABASE_URL"] = "ordinary-production"
    expect(described_class.validate_boot!).to be_nil
    expect(described_class.identity?).to be(false)
  end

  it "keeps demo identity when guest entry is disabled without requiring provisioning permission" do
    configure_runtime
    ENV["QUICKFLOW_GUEST_LOGIN"] = "false"
    expect(described_class.validate_boot!).to be(true)
    expect(described_class.identity?).to be(true)
    expect(described_class.provisioning?).to be_falsey
  end

  Demo::Profile::FORBIDDEN.each do |setting|
    it "rejects inherited #{setting}, even an empty/false value" do
      configure_runtime
      ENV[setting] = setting == "SOLID_QUEUE_IN_PUMA" ? "false" : ""
      expect { described_class.validate_boot! }.to raise_error(Demo::Profile::Unsafe)
    end
  end

  it "rejects provisioning permission outside the explicit Rake task" do
    configure_runtime
    ENV["QUICKFLOW_DEMO_PROVISION"] = "true"
    expect { described_class.validate_boot! }.to raise_error(Demo::Profile::Unsafe)
  end

  %w[database runtime_role provision_role host storage_root allowed_host].each do |setting|
    it "rejects an unrelated #{setting}" do
      configure_runtime
      @target[setting] = "unrelated"
      File.write(@declaration, JSON.generate(@target))
      expect { described_class.validate_boot! }.to raise_error(Demo::Profile::Unsafe)
    end
  end

  it "rejects redirected declarations" do
    configure_runtime
    File.symlink(@declaration, "#{@declaration}.link")
    ENV["QUICKFLOW_DEMO_TARGET"] = "#{@declaration}.link"
    expect { described_class.validate_boot! }.to raise_error(Demo::Profile::Unsafe)
  end

  it "blocks enqueue and delayed enqueue" do
    adapter = Demo::RejectJobsAdapter.new
    expect { adapter.enqueue(Object.new) }.to raise_error(Demo::Profile::Unsafe)
    expect { adapter.enqueue_at(Object.new, Time.now) }.to raise_error(Demo::Profile::Unsafe)
  end

  it "rejects Disk writes without provisioning provenance" do
    storage = Object.new.extend(Demo::ReadOnlyStorage)
    %i[upload delete delete_prefixed compose update_metadata].each do |operation|
      expect { storage.public_send(operation, "synthetic") }.to raise_error(Demo::Profile::Unsafe)
    end
  end

  it "requires direct TLS and the exact declared host and rejects forwarded headers" do
    configure_runtime
    calls = 0
    app = Demo::TransportBoundary.new(->(_env) { calls += 1; [ 200, {}, [] ] })
    valid = { "rack.url_scheme" => "https", "HTTP_HOST" => @target.fetch("allowed_host") }
    expect(app.call(valid).first).to eq(200)
    [ { "rack.url_scheme" => "http" }, { "HTTP_HOST" => "example.invalid" },
      { "HTTP_X_FORWARDED_FOR" => "127.0.0.1" }, { "HTTP_FORWARDED" => "proto=https" } ].each do |change|
      expect(app.call(valid.merge(change)).first).to eq(400)
    end
    expect(calls).to eq(1)
  end
end
