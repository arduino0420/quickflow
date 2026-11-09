# Public certificate evidence only. Never reads Caddy private keys or app secrets.
require "json"
require "pathname"
require "open3"
require "openssl"
require "socket"
require "base64"
require "timeout"
require "time"
module LocalCertificateProof
  ROOT = Pathname.new(__dir__).join("../..").expand_path
  PROJECT = "qfl-check-#{OpenSSL::Digest::SHA256.hexdigest(ROOT.to_s)[0, 10]}"
  BASE = "https://localhost:18444"
  def self.run(*command)
    env = ENV.to_h.slice("HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "DOCKER_CONFIG")
    output, _error, status = Open3.capture3(env, *command, unsetenv_others: true, chdir: ROOT.to_s)
    raise "Certificate proof command failed: #{command.first}" unless status.success?
    output
  end
  def self.docker
    raise "Remote Docker endpoint forbidden" if ENV["DOCKER_HOST"] && !ENV["DOCKER_HOST"].start_with?("unix://")
    context = ENV["DOCKER_CONTEXT"] || run("docker", "context", "show").strip
    endpoint = JSON.parse(run("docker", "context", "inspect", context)).fetch(0).fetch("Endpoints").fetch("docker").fetch("Host")
    raise "Non-local Docker context forbidden" unless endpoint.start_with?("unix://")
    [ "docker", "--context", context ]
  end
  def self.current_caddy
    cli = docker
    ids = run(*cli, "ps", "-q", "--no-trunc", "--filter", "label=com.docker.compose.project=#{PROJECT}", "--filter", "label=com.docker.compose.service=caddy").split
    raise "Expected exactly one local Caddy" unless ids.size == 1
    c = JSON.parse(run(*cli, "inspect", ids.first)).fetch(0)
    labels = c.fetch("Config").fetch("Labels")
    raise "Wrong Caddy identity" unless c.dig("State", "Running") && labels["com.docker.compose.project"] == PROJECT && labels["com.docker.compose.service"] == "caddy"
    data = c.fetch("Mounts").select { |m| m["Destination"] == "/data" }
    raise "Wrong Caddy public certificate volume" unless data.size == 1 && data.first["Type"] == "volume" && data.first["Name"] == "#{PROJECT}_caddy_data"
    ports = c.dig("HostConfig", "PortBindings", "443/tcp")
    raise "Wrong Caddy ingress" unless ports == [ { "HostIp" => "127.0.0.1", "HostPort" => "18444" } ]
    [ cli, c ]
  end
  def self.live_certificate
    Timeout.timeout(10) do
      tcp = TCPSocket.new("127.0.0.1", 18444)
      context = OpenSSL::SSL::SSLContext.new
      context.verify_mode = OpenSSL::SSL::VERIFY_NONE # Inspect public leaf; exact pin comparison follows.
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, context)
      ssl.sync_close = true
      ssl.hostname = "localhost"
      begin
        ssl.connect
        ssl.peer_cert
      ensure
        ssl.close
      end
    end
  end
  def self.generate
    # Full local wrapper checks image, project, network and volume identity first.
    # Pass the same selected Docker context that subsequent public-cert reads use.
    cli = docker
    context = cli.last
    _output, _error, status = Open3.capture3({ "DOCKER_CONTEXT" => context }, ROOT.join("bin/local").to_s, "check", "verify", chdir: ROOT.to_s)
    raise "Local check verification failed" unless status.success?
    cli, container = current_caddy
    pem = run(*cli, "exec", container.fetch("Id"), "cat", "/data/caddy/certificates/local/localhost/localhost.crt")
    cert = OpenSSL::X509::Certificate.new(pem)
    live = live_certificate
    raise "Live TLS leaf differs from dedicated Caddy certificate" unless cert.to_der == live.to_der
    sans = cert.extensions.select { |e| e.oid == "subjectAltName" }.flat_map { |e| e.value.split(/,\s*/) }
    raise "Unexpected certificate SAN" unless sans == [ "DNS:localhost" ]
    raise "Certificate is not currently valid" unless cert.not_before <= Time.now && Time.now < cert.not_after
    report = { base_url: BASE, project: PROJECT, container_id: container.fetch("Id"), image_id: container.fetch("Image"),
      der_sha256: OpenSSL::Digest::SHA256.hexdigest(cert.to_der),
      spki_sha256_base64: Base64.strict_encode64(OpenSSL::Digest::SHA256.digest(cert.public_key.public_to_der)),
      san_dns: [ "localhost" ], not_before: cert.not_before.utc.iso8601, not_after: cert.not_after.utc.iso8601,
      generated_at: Time.now.utc.iso8601 }
    path = ROOT.join(".local/check/browser-certificate-proof.json")
    File.write(path, JSON.pretty_generate(report) + "\n", mode: "w", perm: 0600)
    puts "Verified local Caddy public certificate proof written; no private key was read."
    report
  end
end
LocalCertificateProof.generate if $PROGRAM_NAME == __FILE__
