#!/usr/bin/env ruby
# Local verification only. Reads the private context created by the fresh-cluster harness.
require "json"
require "uri"
require "openssl"
require "net/http"
require "open3"
require "timeout"
require "nokogiri"
require "pg"

root = File.expand_path("..", __dir__)
control = File.expand_path(ARGV.fetch(0))
raise "Unexpected local control directory" unless control.start_with?(File.join(root, "tmp", "production-demo-control-")) && File.realpath(control) == control
context = JSON.parse(File.read(File.join(control, "private-test-context.json")))
target = context.fetch("target")
env = context.fetch("env").merge("QUICKFLOW_DEMO_DATABASE_URL" => context.fetch("urls").fetch("runtime"))
secrets = context.fetch("urls").values.map { |url| URI.parse(url).password } + [ env.fetch("QUICKFLOW_DEMO_SESSION_SECRET") ]
database = PG.connect(context.fetch("urls").fetch("runtime"))
examples = database.exec(<<~SQL).to_a
  SELECT assignments.id, classrooms.id AS classroom_id, schools.school_code, submissions.id AS submission_id
  FROM assignments JOIN teachers ON teachers.id=assignments.teacher_id
  JOIN schools ON schools.id=teachers.school_id
  JOIN classrooms ON classrooms.school_id=schools.id
  JOIN submissions ON submissions.assignment_id=assignments.id ORDER BY schools.school_code
SQL
database.finish
redact = ->(text) { secrets.reduce(text) { |value, secret| value.gsub(secret, "[REDACTED]") } }
output, error, status = Open3.capture3(env.merge("QUICKFLOW_GUEST_LOGIN" => "false"), "bin/rails", "runner", "script/production_demo_runtime_checks.rb", chdir: root, unsetenv_others: true)
File.write(File.join(control, "runtime-boot.log"), redact.call(output + error))
raise "Runtime boot failed; redacted log retained" unless status.success?
unless File.file?(File.join(root, "public/assets/.manifest.json"))
  output, error, status = Open3.capture3(env, "bin/rails", "assets:precompile", chdir: root, unsetenv_others: true)
  File.write(File.join(control, "assets.log"), redact.call(output + error))
  raise "Asset compilation failed" unless status.success?
end

ca_key = OpenSSL::PKey::RSA.new(2048)
ca = OpenSSL::X509::Certificate.new
ca.version = 2
ca.serial = 1
ca.subject = ca.issuer = OpenSSL::X509::Name.parse("/CN=QuickFlow local verification CA")
ca.public_key = ca_key.public_key
ca.not_before = Time.now - 60
ca.not_after = Time.now + 3600
factory = OpenSSL::X509::ExtensionFactory.new
factory.subject_certificate = factory.issuer_certificate = ca
ca.add_extension(factory.create_extension("basicConstraints", "CA:TRUE", true))
ca.add_extension(factory.create_extension("keyUsage", "keyCertSign,cRLSign", true))
ca.sign(ca_key, OpenSSL::Digest.new("SHA256"))
key = OpenSSL::PKey::RSA.new(2048)
cert = OpenSSL::X509::Certificate.new
cert.version = 2
cert.serial = 2
cert.subject = OpenSSL::X509::Name.parse("/CN=#{target.fetch('allowed_host')}")
cert.issuer = ca.subject
cert.public_key = key.public_key
cert.not_before = ca.not_before
cert.not_after = ca.not_after
factory.subject_certificate = cert
factory.issuer_certificate = ca
cert.add_extension(factory.create_extension("basicConstraints", "CA:FALSE", true))
cert.add_extension(factory.create_extension("keyUsage", "digitalSignature,keyEncipherment", true))
cert.add_extension(factory.create_extension("extendedKeyUsage", "serverAuth"))
cert.add_extension(factory.create_extension("subjectAltName", "DNS:#{target.fetch('allowed_host')}"))
cert.sign(ca_key, OpenSSL::Digest.new("SHA256"))
{ "server.key" => key.to_pem, "server.crt" => cert.to_pem, "client-ca.crt" => ca.to_pem }.each do |name, value|
  File.open(File.join(control, name), File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(value) }
end
env = env.merge("QUICKFLOW_DEMO_BIND" => "ssl://127.0.0.1:#{target.fetch('https_port')}?key=#{control}/server.key&cert=#{control}/server.crt",
  "QUICKFLOW_DEMO_PIDFILE" => File.join(control, "puma.pid"))
log = File.open(File.join(control, "https-server.log"), "w", 0o600)
pid = nil
begin
  pid = Process.spawn(env, "bin/demo-web", chdir: root, unsetenv_others: true, out: log, err: log)
  http = Net::HTTP.new(target.fetch("allowed_host"), target.fetch("https_port"), nil)
  http.ipaddr = "127.0.0.1"
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_PEER
  http.verify_hostname = true
  http.ca_file = File.join(control, "client-ca.crt")
  http.open_timeout = 2
  http.read_timeout = 15
  response = nil
  Timeout.timeout(40) do
    loop do
      raise "Production process exited before serving" if Process.waitpid(pid, Process::WNOHANG)
      begin
        response = http.get("/")
        break
      rescue Errno::ECONNREFUSED, OpenSSL::SSL::SSLError
        sleep 0.2
      end
    end
  end
  raise "Home failed: #{response.code}" unless response.code == "200"
  assets = Nokogiri::HTML(response.body).css('link[rel="stylesheet"][href],script[src]').map { |node| node["href"] || node["src"] }
  raise "No application assets" if assets.empty?
  assets.each do |path|
    next unless path.start_with?("/assets/")
    raise "Asset unavailable: #{path}" unless http.get(path).code == "200"
  end
  raise "Missing no-store" unless response["cache-control"].include?("no-store")
  token = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')&.[]("content")
  raise "Missing CSRF token" unless token
  cookie = response.get_fields("set-cookie").find { |item| item.start_with?("__Host-qfd-") }
  raise "Unsafe cookie" unless cookie && %w[secure httponly samesite=strict path=/].all? { |flag| cookie.downcase.include?(flag) } && !cookie.downcase.include?("domain=")
  session_cookie = cookie.split(";", 2).first
  [ nil, "invalid" ].each do |value|
    request = Net::HTTP::Post.new("/guest/teacher", "Cookie" => session_cookie)
    request.set_form_data(value ? { authenticity_token: value } : {})
    result = http.request(request)
    raise "CSRF accepted: #{result.code}" unless result.code == "422"
  end
  own = examples.find { |item| item.fetch("school_code") == "DEMO1" }
  other = examples.find { |item| item.fetch("school_code") == "DEMO2" }
  %w[teacher admin student].each do |role|
    request = Net::HTTP::Post.new("/guest/#{role}", "Cookie" => session_cookie)
    request.set_form_data(authenticity_token: token)
    result = http.request(request)
    raise "Guest #{role} start failed: #{result.code}" unless result.code == "303"
    previous_cookie = session_cookie
    session_cookie = result.get_fields("set-cookie").find { |item| item.start_with?("__Host-qfd-") }.split(";", 2).first
    result = http.get(URI(result["location"]).request_uri, "Cookie" => session_cookie)
    raise "#{role} view failed: #{result.code}" unless result.code == "200"
    raise "Missing explicit guest label" unless result.body.force_encoding("UTF-8").include?("ゲスト")
    refreshed_cookie = result.get_fields("set-cookie")&.find { |item| item.start_with?("__Host-qfd-") }
    session_cookie = refreshed_cookie.split(";", 2).first if refreshed_cookie
    token = Nokogiri::HTML(result.body).at_css('meta[name="csrf-token"]')["content"]
    if role == "teacher"
      [ "/assignments/#{own.fetch('id')}", "/assignments/#{own.fetch('id')}/submissions/#{own.fetch('submission_id')}" ].each do |path|
        raise "Teacher read failed: #{path}" unless http.get(path, "Cookie" => session_cookie).code == "200"
      end
      pdf = http.get("/assignments/#{own.fetch('id')}/submissions/#{own.fetch('submission_id')}/answer", "Cookie" => session_cookie)
      raise "Teacher answer PDF failed" unless pdf.code == "200" && pdf.body.start_with?("%PDF-")
      result = http.get("/assignments/#{own.fetch('id')}/export.xlsx?classroom_id=#{own.fetch('classroom_id')}", "Cookie" => session_cookie)
      raise "Excel failed: #{result.code}" unless result.code == "200" && result.body.start_with?("PK")
      raise "Other school visible" unless http.get("/assignments/#{other.fetch('id')}", "Cookie" => session_cookie).code == "404"
    elsif role == "student"
      [ "/student/assignments/#{own.fetch('id')}" ].each do |path|
        raise "Student read failed: #{path}" unless http.get(path, "Cookie" => session_cookie).code == "200"
      end
      legacy_result = http.get("/student/assignments/#{own.fetch('id')}/result", "Cookie" => session_cookie)
      raise "Legacy result redirect changed" unless legacy_result.code == "303" && URI(legacy_result["location"]).path == "/student/assignments/#{own.fetch('id')}"
      result = http.get("/student/assignments/#{own.fetch('id')}/material", "Cookie" => session_cookie)
      raise "PDF failed: #{result.code}" unless result.code == "200" && result.body.start_with?("%PDF-")
      answer = http.get("/student/assignments/#{own.fetch('id')}/answer", "Cookie" => session_cookie)
      raise "Student answer PDF failed" unless answer.code == "200" && answer.body.start_with?("%PDF-")
      raise "Other school visible" unless http.get("/student/assignments/#{other.fetch('id')}", "Cookie" => session_cookie).code == "404"
      raise "Old role cookie remains active" unless http.get("/admin", "Cookie" => previous_cookie).code == "401"
    else
      %w[/admin/teachers /admin/students].each do |path|
        raise "Admin read failed: #{path}" unless http.get(path, "Cookie" => session_cookie).code == "200"
      end
    end
    [ Net::HTTP::Post, Net::HTTP::Patch, Net::HTTP::Put, Net::HTTP::Delete ].each do |verb|
      path = verb == Net::HTTP::Post ? "/assignments" : "/assignments/#{own.fetch('id')}"
      request = verb.new(path, "Cookie" => session_cookie)
      request.set_form_data(authenticity_token: token)
      mutation = http.request(request)
      raise "Business verb #{verb} expected 403, received #{mutation.code}" unless mutation.code == "403"
    end
  end
  old_cookie = session_cookie
  request = Net::HTTP::Delete.new("/student/logout", "Cookie" => session_cookie)
  request.set_form_data(authenticity_token: token)
  raise "Logout failed" unless http.request(request).code == "303"
  raise "Logged-out cookie remains active" unless http.get("/student/assignments", "Cookie" => old_cookie).code == "401"
  fresh = http.get("/")
  token = Nokogiri::HTML(fresh.body).at_css('meta[name="csrf-token"]')["content"]
  cookie = fresh.get_fields("set-cookie").find { |item| item.start_with?("__Host-qfd-") }.split(";", 2).first
  request = Net::HTTP::Post.new("/guest/student", "Cookie" => cookie)
  request.set_form_data(authenticity_token: token)
  fresh = http.request(request)
  raise "Expiry fixture start failed: #{fresh.code}" unless fresh.code == "303"
  cookie = fresh.get_fields("set-cookie").find { |item| item.start_with?("__Host-qfd-") }.split(";", 2).first
  raise "Expiry fixture not active" unless http.get("/student/assignments", "Cookie" => cookie).code == "200"
  database = PG.connect(context.fetch("urls").fetch("runtime"))
  database.exec("SET TIME ZONE 'UTC'")
  expired = database.exec("UPDATE authentication_attempt_buckets SET expires_at=now()-interval '1 second' WHERE key_digest=(SELECT key_digest FROM authentication_attempt_buckets WHERE attempts=0 AND expires_at>now() ORDER BY expires_at DESC LIMIT 1) RETURNING key_digest")
  raise "Expiry fixture nonce missing" unless expired.ntuples == 1
  database.finish
  raise "Expired nonce accepted" unless http.get("/student/assignments", "Cookie" => cookie).code == "401"
  raise "Normal login available" unless http.get("/login").code == "403"
  normal_cookie = File.read(File.join(control, "old-normal-cookie"))
  raise "Old ordinary session admitted" unless http.get("/assignments", "Cookie" => normal_cookie).code == "403"
  raise "Untrusted forwarded header accepted" unless http.get("/", "X-Forwarded-For" => "203.0.113.1").code == "400"
  raise "Unknown host accepted" unless http.get("/", "Host" => "example.invalid").code == "400"
  puts "Production runtime boot, CA-verified HTTPS, three roles, PDF/Excel, scope, mutation verbs, switch/logout, CSRF, cookie, host and forwarded-header checks passed"
ensure
  if pid
    begin
      Process.kill("TERM", pid)
      Timeout.timeout(15) { Process.wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
  log.close
end

# A separate production process proves entry OFF retains identity-wide controls.
log = File.open(File.join(control, "https-entry-off.log"), "w", 0o600)
pid = nil
begin
  pid = Process.spawn(env.merge("QUICKFLOW_GUEST_LOGIN" => "false"), "bin/demo-web", chdir: root, unsetenv_others: true, out: log, err: log)
  response = nil
  Timeout.timeout(40) do
    loop do
      raise "Entry-OFF process exited" if Process.waitpid(pid, Process::WNOHANG)
      begin
        response = http.get("/")
        break
      rescue Errno::ECONNREFUSED, OpenSSL::SSL::SSLError
        sleep 0.2
      end
    end
  end
  raise "Entry-OFF home failed" unless response.code == "200"
  raise "Entry-OFF guest link remains" if response.body.include?("/guest/teacher")
  token = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')["content"]
  cookie = response.get_fields("set-cookie").find { |item| item.start_with?("__Host-qfd-") }.split(";", 2).first
  request = Net::HTTP::Post.new("/login", "Cookie" => cookie)
  request.set_form_data(authenticity_token: token, user_id: "synthetic", password: "synthetic")
  raise "Entry-OFF password login accepted" unless http.request(request).code == "403"
  request = Net::HTTP::Post.new("/guest/teacher", "Cookie" => cookie)
  request.set_form_data(authenticity_token: token)
  raise "Entry-OFF route remains" unless http.request(request).code == "404"
  raise "Entry-OFF old ordinary session admitted" unless http.get("/assignments", "Cookie" => normal_cookie).code == "403"
  raise "Entry-OFF anonymous business access admitted" unless http.get("/student/assignments").code == "403"
  puts "Separate production process with guest entry OFF: no entry route, password login, old ordinary session or anonymous business access"
ensure
  if pid
    begin
      Process.kill("TERM", pid)
      Timeout.timeout(15) { Process.wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end
  log.close
end
