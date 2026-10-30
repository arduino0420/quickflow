require "json"
require "digest"
require "pathname"
require "net/http"
require "importmap-rails"
require "importmap/map"

# Maintenance only: do not boot Rails or load credentials to inspect static assets.
class JavascriptDependencyAudit
  class InvalidInventory < StandardError; end
  class Unavailable < StandardError; end

  ENDPOINT = URI("https://registry.npmjs.org/-/npm/v1/security/advisories/bulk")

  def initialize(root:, transport: nil)
    @root = Pathname.new(root)
    @transport = transport || method(:request)
  end

  def inventory
    entries = JSON.parse(@root.join("config/javascript_dependencies.json").read)
    raise InvalidInventory, "empty_inventory" unless entries.is_a?(Array) && entries.any?

    begin
      map = Importmap::Map.new.draw(@root.join("config/importmap.rb"))
    rescue StandardError, SyntaxError
      raise InvalidInventory, "invalid_importmap"
    end
    raise InvalidInventory, "unsupported_directory" unless map.directories.keys.all? { |dir| dir.start_with?("app/javascript/") && !dir.include?("..") }

    external = map.packages.reject { |_, pin| own_source?(pin.path) }
    names = entries.map { |entry| entry.is_a?(Hash) ? entry["pin"] : nil }
    unless names.all? { |name| name.is_a?(String) } && names.uniq.length == names.length && names.sort == external.keys.sort
      raise InvalidInventory, "uncovered_or_stale_pins"
    end

    entries.each do |entry|
      unless %w[registry package version pin asset sha256].all? { |key| entry[key].is_a?(String) } &&
          %w[npm rubygems].include?(entry["registry"]) && entry["version"].match?(/\A\d+\.\d+\.\d+\z/) &&
          entry["package"].match?(/\A(?:@[a-z0-9_.-]+\/)?[a-z0-9_.-]+\z/) &&
          entry["sha256"].match?(/\A[0-9a-f]{64}\z/) && entry["asset"] == external.fetch(entry["pin"]).path
        raise InvalidInventory, "invalid_dependency"
      end

      if entry["gem"]
        spec = Gem.loaded_specs[entry["gem"]]
        raise InvalidInventory, "gem_version_changed" unless spec && spec.version.to_s == entry["gem_version"]
        raise InvalidInventory, "invalid_gem_asset" unless entry["asset"].match?(/\A[\w.-]+\.js\z/)
        path = Pathname.new(spec.full_gem_path).join("app/assets/javascripts", entry["asset"])
        if entry["registry"] == "rubygems" && [ entry["package"], entry["version"] ] != [ spec.name, spec.version.to_s ]
          raise InvalidInventory, "incorrect_gem_identity"
        end
      else
        raise InvalidInventory, "invalid_public_asset" unless entry["registry"] == "npm" && entry["asset"].start_with?("/vendor/") && !entry["asset"].include?("..")
        path = @root.join("public", entry["asset"].delete_prefix("/"))
      end
      raise InvalidInventory, "asset_changed_or_missing" unless path.file? && Digest::SHA256.file(path).hexdigest == entry["sha256"]
    end
    raise InvalidInventory, "no_npm_dependencies" unless entries.any? { |entry| entry["registry"] == "npm" }
    entries
  rescue JSON::ParserError, SystemCallError
    raise InvalidInventory, "missing_or_invalid_manifest"
  end

  def audit(entries = inventory)
    packages = entries.select { |entry| entry["registry"] == "npm" }.group_by { |entry| entry["package"] }
      .transform_values { |items| items.map { |entry| entry["version"] }.uniq }
    raise InvalidInventory, "no_npm_dependencies" if packages.empty?

    response = @transport.call(packages)
    raise Unavailable, "http_status_#{response.code}" unless response.code == "200"
    body = response.body
    raise Unavailable, "invalid_response" unless body.is_a?(String) && body.bytesize <= 1_048_576
    advisories = JSON.parse(body)
    unless advisories.is_a?(Hash) && (advisories.keys - packages.keys).empty? &&
        advisories.values.all? { |items| items.is_a?(Array) && items.all? { |item| item.is_a?(Hash) && item["title"].is_a?(String) } }
      raise Unavailable, "invalid_response"
    end
    { packages: packages, advisories: advisories }
  rescue JSON::ParserError
    raise Unavailable, "invalid_response"
  end

  private

  def own_source?(path)
    !path.start_with?("/", "http:", "https:") && !path.include?("..") && @root.join("app/javascript", path).file?
  end

  def request(packages)
    Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true, open_timeout: 10, read_timeout: 30, write_timeout: 30) do |http|
      http.post(ENDPOINT.request_uri, JSON.generate(packages), "Content-Type" => "application/json")
    end
  rescue StandardError => error
    # Never print proxy details, response bodies, or other transport exception text.
    raise Unavailable, "transport_#{error.class.name}"
  end
end
