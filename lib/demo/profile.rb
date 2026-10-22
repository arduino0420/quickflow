require "json"
require "uri"
require "pathname"

module Demo
  # Independent of Rails autoloading so configuration/Puma can fail before boot.
  module Profile
    class Unsafe < StandardError; end
    KEYS = %w[version isolation_id database runtime_role provision_role host port storage_root allowed_host https_port data_directory system_identifier].freeze
    FORBIDDEN = %w[DATABASE_URL PRIMARY_DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL
      QUICKFLOW_DATABASE_PASSWORD QUICKFLOW_DEMO_SEED SECRET_KEY_BASE RAILS_MASTER_KEY SOLID_QUEUE_IN_PUMA].freeze

    def self.identity?
      ENV["QUICKFLOW_DEMO_PROFILE"] == "production"
    end

    def self.provisioning?
      identity? && ENV["QUICKFLOW_DEMO_PROVISION"] == "true" && defined?(Rake) && Rake.respond_to?(:application) &&
        Rake.application.top_level_tasks == [ "demo:provision" ]
    end

    def self.settings
      path = Pathname.new(ENV.fetch("QUICKFLOW_DEMO_TARGET"))
      raise Unsafe, "Absolute, unredirected target declaration required" unless path.absolute? && path.file? && path.realpath == path
      value = JSON.parse(path.read)
      raise Unsafe, "Unknown demo declaration contract" unless value.is_a?(Hash) && value.keys.sort == KEYS.sort && value["version"] == 1
      token = value["isolation_id"]
      raise Unsafe, "Invalid isolation ID" unless token.is_a?(String) && token.match?(/\A[0-9a-f]{32}\z/)
      suffix = token[0, 16]
      expected = { "database" => "quickflow_demo_#{suffix}", "runtime_role" => "qfd_runtime_#{suffix}",
        "provision_role" => "qfd_provision_#{suffix}", "host" => "127.0.0.1" }
      raise Unsafe, "Dedicated declared identity required" unless expected.all? { |key, item| value[key] == item }
      raise Unsafe, "Non-default local endpoint required" unless value["port"].is_a?(Integer) && (1024..65535).cover?(value["port"]) && value["port"] != 5432
      raise Unsafe, "Unique dedicated hostname required" unless value["allowed_host"].is_a?(String) && value["allowed_host"].match?(/\Aqfd-#{suffix}\.(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)*[a-z][a-z0-9-]*[a-z0-9]\z/)
      raise Unsafe, "Dedicated HTTPS port required" unless value["https_port"].is_a?(Integer) && (1024..65535).cover?(value["https_port"]) && value["https_port"] != value["port"]
      root = Pathname.new(value["storage_root"].to_s)
      expected_root = Pathname.new(__dir__).join("../../tmp/production-demo-#{token}").expand_path
      raise Unsafe, "Dedicated absolute storage declaration required" unless root.absolute? && root == expected_root
      expected_cluster = Pathname.new(__dir__).join("../../tmp/production-demo-pg-#{token}").expand_path.to_s
      raise Unsafe, "Cluster identity required" unless value["data_directory"] == expected_cluster && value["system_identifier"].to_s.match?(/\A[0-9]+\z/)
      value.freeze
    rescue KeyError, JSON::ParserError, SystemCallError => error
      raise Unsafe, "Invalid demo declaration (#{error.class})"
    end

    def self.validate_bind!
      target = settings
      uri = URI.parse(ENV.fetch("QUICKFLOW_DEMO_BIND"))
      control = Pathname.new(__dir__).join("../../tmp/production-demo-control-#{target.fetch('isolation_id')}").expand_path
      options = URI.decode_www_form(uri.query.to_s).to_h
      expected = { "key" => control.join("server.key").to_s, "cert" => control.join("server.crt").to_s }
      raise Unsafe, "Declared loopback TLS binding required" unless uri.scheme == "ssl" && uri.host == "127.0.0.1" && uri.port == target["https_port"] && options == expected && uri.path.to_s.empty? && uri.fragment.nil?
      expected.each_value do |path|
        candidate = Pathname.new(path)
        raise Unsafe, "TLS files redirected or missing" unless candidate.file? && candidate.realpath == candidate
      end
      true
    rescue KeyError, URI::InvalidURIError, SystemCallError
      raise Unsafe, "Declared TLS binding required"
    end

    def self.validate_boot!
      value = ENV["QUICKFLOW_DEMO_PROFILE"]
      raise Unsafe, "Unknown demo profile" unless value.nil? || value.empty? || value == "off" || value == "production"
      return unless identity?
      raise Unsafe, "Production mode required" unless ENV["RAILS_ENV"] == "production"
      raise Unsafe, "Ambiguous or forbidden inherited setting" if FORBIDDEN.any? { |name| ENV.key?(name) }
      raise Unsafe, "External service credentials forbidden" if ENV.keys.any? { |name| name.start_with?("AWS_", "OPENAI_") }
      raise Unsafe, "Puma workers forbidden" if ENV.key?("WEB_CONCURRENCY") && ENV["WEB_CONCURRENCY"] != "0"
      raise Unsafe, "Provisioning permission is task-only" if ENV.key?("QUICKFLOW_DEMO_PROVISION") && !provisioning?
      secret = ENV["QUICKFLOW_DEMO_SESSION_SECRET"].to_s
      raise Unsafe, "Independent demo session secret required" unless secret.match?(/\A[0-9a-f]{128}\z/)
      target = settings
      url = URI.parse(ENV.fetch("QUICKFLOW_DEMO_DATABASE_URL"))
      role = provisioning? ? target.fetch("provision_role") : target.fetch("runtime_role")
      raise Unsafe, "Dedicated explicit URL required" unless %w[postgres postgresql].include?(url.scheme) && url.host == target["host"] && url.port == target["port"] &&
        url.path == "/#{target['database']}" && URI.decode_www_form_component(url.user.to_s) == role && url.password.to_s.match?(/\A[0-9a-f]{64}\z/) && url.query.nil? && url.fragment.nil?
      true
    rescue KeyError, URI::InvalidURIError
      raise Unsafe, "Dedicated explicit URL required"
    end
  end
end
