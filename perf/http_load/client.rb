require "cgi"
require "json"
require "net/http"
require "securerandom"
require "uri"
require "pg"

RUN_ID = ENV.fetch("QUICKFLOW_HTTP_LOAD_RUN_ID")
FIXTURE = JSON.parse(File.read("tmp/http_load_fixture_#{RUN_ID}.json"))
PDF = File.binread("spec/fixtures/files/material.pdf")
BASE = URI("http://127.0.0.1:3000")

class StudentClient
  def initialize(number)
    @number = number
    @cookie = nil
  end

  def request(method, path, body: nil, type: nil, headers: {})
    uri = BASE + path
    request = Net::HTTP.const_get(method.capitalize).new(uri)
    request["Cookie"] = @cookie if @cookie
    request["Content-Type"] = type if type
    headers.each { |name, value| request[name] = value }
    request.body = body if body
    response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 60) { |http| http.request(request) }
    cookies = response.get_fields("set-cookie")
    @cookie = cookies.first.split(";", 2).first if cookies&.any?
    response
  end

  def token(html)
    value = html.match(/<meta name="csrf-token" content="([^"]+)"/)&.captures&.first ||
      html.match(/<meta content="([^"]+)" name="csrf-token"/)&.captures&.first
    raise "CSRF token missing" unless value

    CGI.unescapeHTML(value)
  end

  def login
    login_page = request("get", "/student/login")
    raise "login page #{login_page.code}" unless login_page.code == "200"

    params = URI.encode_www_form("student_session[school_code]" => FIXTURE.fetch("school_code"),
      "student_session[grade]" => "1", "student_session[class_number]" => "1",
      "student_session[attendance_number]" => @number.to_s,
      "student_session[password]" => FIXTURE.fetch("password"), "authenticity_token" => token(login_page.body))
    result = request("post", "/student/login", body: params, type: "application/x-www-form-urlencoded")
    raise "login #{result.code}" unless result.code == "303"
  end

  def prepare(assignment_id, handwritten: false)
    page = request("get", "/student/assignments/#{assignment_id}")
    raise "assignment page #{page.code}" unless page.code == "200"

    @csrf = token(page.body)
    return unless handwritten

    preview = request("get", "/student/assignments/#{assignment_id}/pdf_preview")
    raise "preview #{preview.code}" unless preview.code == "200"

    @context = CGI.unescapeHTML(preview.body.match(/data-pdf-preview-draft-context-value="([^"]+)"/)&.captures&.first.to_s)
    raise "draft context missing" if @context.empty?

    draft = request("put", "/student/assignments/#{assignment_id}/answer_draft",
      body: JSON.generate(draft_data: { format_version: 1, pages: [ { page_number: 1, operations: [] } ] }, expected_version: nil),
      type: "application/json", headers: { "X-CSRF-Token" => @csrf, "X-Draft-Context" => @context })
    raise "draft #{draft.code}" unless draft.code == "200"

    @version = JSON.parse(draft.body).fetch("draft").fetch("version")
  end

  def submit(assignment_id, handwritten: false, csrf: true)
    boundary = "quickflow#{SecureRandom.hex(12)}"
    fields = handwritten ? { "draft_version" => @version.to_s } : {}
    fields["authenticity_token"] = @csrf if csrf
    body = fields.map { |name, value| "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n" }.join
    body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"submission[answer_file]\"; filename=\"answer.pdf\"\r\nContent-Type: application/pdf\r\n\r\n"
    body << PDF << "\r\n--#{boundary}--\r\n"
    headers = handwritten ? { "X-Handwritten-Submission" => "1", "X-Draft-Context" => @context, "Accept" => "application/json" } : {}
    headers["X-CSRF-Token"] = @csrf if csrf
    request("post", "/student/assignments/#{assignment_id}/submission", body: body,
      type: "multipart/form-data; boundary=#{boundary}", headers: headers)
  end
end

def monitor(stop, samples)
  connection = PG.connect(ENV.fetch("DATABASE_URL"))
  loop do
    break unless stop.empty?

    row = connection.exec(<<~SQL).first
      SELECT count(*) AS connections,
        count(*) FILTER (WHERE wait_event_type = 'Lock') AS lock_waiters,
        count(*) FILTER (WHERE wait_event = 'advisory') AS advisory_waiters
      FROM pg_stat_activity WHERE datname = 'quickflow_test'
    SQL
    rss_kb = Dir.glob("/proc/[0-9]*/cmdline").filter_map do |path|
      command = File.read(path).tr("\0", " ") rescue ""
      next unless command.include?("bin/rails server") || command.include?("puma")

      File.read(File.join(File.dirname(path), "status"))[/^VmRSS:\s+(\d+)/, 1].to_i rescue nil
    end.max
    samples << { observed_at: Process.clock_gettime(Process::CLOCK_MONOTONIC),
      connections: row.fetch("connections").to_i, lock_waiters: row.fetch("lock_waiters").to_i,
      advisory_waiters: row.fetch("advisory_waiters").to_i, rss_kb: rss_kb }
    sleep 0.01
  end
ensure
  connection&.close
end

mode = ARGV.fetch(0)
unless %w[safety ordinary handwritten].include?(mode)
  raise "unknown mode"
end

if mode == "safety"
  client = StudentClient.new(31)
  client.login
  assignment = FIXTURE.fetch("assignments").fetch("canary")
  client.prepare(assignment)
  absent = client.submit(assignment, csrf: false)
  raise "missing CSRF was accepted: #{absent.code}" unless %w[403 422].include?(absent.code)
  db = PG.connect(ENV.fetch("DATABASE_URL"))
  count_after_rejection = db.exec_params("SELECT count(*) FROM submissions WHERE assignment_id = $1", [ assignment ]).first.fetch("count").to_i
  db.close
  raise "CSRF rejection created a submission" unless count_after_rejection.zero?

  valid = client.submit(assignment)
  raise "valid CSRF was rejected: #{valid.code}" unless valid.code == "303"

  puts JSON.generate(no_csrf_status: absent.code.to_i, no_csrf_submissions: count_after_rejection,
    valid_csrf_status: valid.code.to_i)
  exit
end

assignment = FIXTURE.fetch("assignments").fetch(mode)
handwritten = mode == "handwritten"
clients = (1..30).map do |number|
  StudentClient.new(number).tap { |client| client.login; client.prepare(assignment, handwritten: handwritten) }
end
ready = Queue.new
start = Queue.new
samples = []
stop = Queue.new
watcher = Thread.new { monitor(stop, samples) }
threads = clients.map do |client|
  Thread.new do
    ready << true
    start.pop
    begun = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = client.submit(assignment, handwritten: handwritten)
    { status: response.code.to_i, elapsed_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - begun) * 1000).round(1) }
  rescue StandardError => error
    { error: error.class.name, message: error.message.to_s[0, 120] }
  end
end
30.times { ready.pop }
trial_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
30.times { start << true }
results = threads.map { |thread| thread.join(70) ? thread.value : { error: "timeout" } }
total_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - trial_started) * 1000).round(1)
stop << true
watcher.join(5)
elapsed = results.filter_map { |result| result[:elapsed_ms] }.sort
summary = { mode: mode, statuses: results.map { |result| result[:status] }, errors: results.filter_map { |result| result[:error] },
  response_ms: results.map { |result| result[:elapsed_ms] },
  median_ms: elapsed.empty? ? nil : ((elapsed[(elapsed.size - 1) / 2] + elapsed[elapsed.size / 2]) / 2.0).round(1),
  p95_ms: elapsed.empty? ? nil : elapsed[(elapsed.size * 0.95).ceil - 1], max_ms: elapsed.max,
  total_ms: total_ms, max_db_connections: samples.map { |sample| sample[:connections] }.max,
  max_lock_waiters: samples.map { |sample| sample[:lock_waiters] }.max,
  max_advisory_waiters: samples.map { |sample| sample[:advisory_waiters] }.max,
  sampled_advisory_wait_ms: samples.each_cons(2).sum { |first, second|
    first[:advisory_waiters] * (second[:observed_at] - first[:observed_at]) * 1000
  }.round(1),
  max_rss_kb: samples.filter_map { |sample| sample[:rss_kb] }.max }
File.write("tmp/http_load_#{RUN_ID}_#{mode}.json", JSON.pretty_generate(summary))
puts JSON.generate(summary)
raise "submission failures" unless summary[:errors].empty? && summary[:statuses] == Array.new(30, handwritten ? 200 : 303)
