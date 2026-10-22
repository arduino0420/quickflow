require_relative "client"
require "digest"

mode = ARGV.fetch(0)
raise "unknown sustained mode" unless %w[sustained_legacy sustained_ack sustained_append].include?(mode)
seconds = Integer(ENV.fetch("QUICKFLOW_SUSTAINED_SECONDS", "180"))
raise "trial must last 2–10 minutes" unless seconds.between?(120, 600)
ack = mode != "sustained_legacy"
appending = mode == "sustained_append"
assignment = FIXTURE.fetch("assignments").fetch(mode)

class StudentClient
  def draft_headers(ack: false)
    { "X-CSRF-Token" => @csrf, "X-Draft-Context" => @context }.tap do |headers|
      headers["X-Draft-Response"] = "acknowledgment" if ack
    end
  end

  def put_snapshot(assignment, snapshot, version, ack:, append_counts: nil)
    payload = if append_counts
      { append_data: { format_version: 1, pages: snapshot[:pages].each_with_index.map do |page, index|
        { page_number: page[:page_number], operations: page[:operations].drop(append_counts[index]) }
      end } }
    else
      { draft_data: snapshot }
    end
    body = JSON.generate(payload.merge(expected_version: version))
    begun = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = request("put", "/student/assignments/#{assignment}/answer_draft", body: body,
      type: "application/json", headers: draft_headers(ack: ack))
    [ response, { ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - begun) * 1000).round(1),
      sent_bytes: body.bytesize, received_bytes: response.body.bytesize, status: response.code.to_i } ]
  end

  def supports_append?(assignment)
    response = request("get", "/student/assignments/#{assignment}/answer_draft", headers: draft_headers(ack: true))
    response.code == "200" && JSON.parse(response.body)["append_supported"] == true
  end

  def remote_draft(assignment)
    response = request("get", "/student/assignments/#{assignment}/answer_draft", headers: draft_headers)
    raise "draft GET failed" unless response.code == "200"

    JSON.parse(response.body).fetch("draft")
  end

  def submit_unique(assignment, version, attempt, pdf)
    boundary = "qf#{SecureRandom.hex(12)}"
    body = { "draft_version" => version.to_s, "submission_token" => attempt }.map do |key, value|
      "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{key}\"\r\n\r\n#{value}\r\n"
    end.join
    body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"submission[answer_file]\"; filename=\"answer.pdf\"\r\nContent-Type: application/pdf\r\n\r\n"
    body << pdf << "\r\n--#{boundary}--\r\n"
    request("post", "/student/assignments/#{assignment}/submission", body: body,
      type: "multipart/form-data; boundary=#{boundary}", headers: draft_headers.merge(
        "X-Handwritten-Submission" => "1", "Accept" => "application/json"))
  end
end

def stroke(number, id)
  # Dense synthetic curves, fractional coordinates and ordered erasing; no real answers.
  { id: id, tool: id % 7 == 0 ? "eraser" : "pen", color: "#000000", width: id % 7 == 0 ? 8 : 1.2,
    points: Array.new(150) { |point| [ 20 + number * 3 + point / 11.0, 30 + id % 180 + Math.sin(point / 13.0) ] } }
end

clients = (1..30).map { |number| StudentClient.new(number).tap { |client| client.login; client.prepare(assignment, handwritten: true) } }
start = Queue.new
stop = Queue.new
samples = []
watcher = Thread.new { monitor(stop, samples) }
begun = Process.clock_gettime(Process::CLOCK_MONOTONIC)
threads = clients.each_with_index.map do |client, index|
  Thread.new do
    start.pop
    number = index + 1
    operations = []
    data = { format_version: 1, pages: [ { page_number: 1, operations: operations } ] }
    version = 0
    raise "append negotiation failed" if appending && !client.supports_append?(assignment)

    confirmed_counts = [ 0 ]
    requests = []
    expected_conflicts = 0
    rounds = seconds / 5
    rounds.times do |round|
      target = begun + round * 5
      sleep [ target - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0 ].max
      8.times { operations << stroke(number, operations.length + 1) }
      response, metric = client.put_snapshot(assignment, data, version, ack: ack, append_counts: appending ? confirmed_counts : nil)
      requests << metric
      raise "save failed with HTTP #{response.code}" unless response.code == "200"

      version = JSON.parse(response.body).fetch("draft").fetch("version")
      # Simulate a lost success response: only GET, compare every coordinate, then continue.
      if round % 6 == 0
        remote = client.remote_draft(assignment)
        raise "lost-response reconciliation mismatch" unless remote.fetch("version") == version && remote.fetch("pages") == JSON.parse(JSON.generate(data[:pages]))
      end
      if round == 1
        stale, = client.put_snapshot(assignment, data, 0, ack: ack)
        raise "stale tab was accepted" unless stale.code == "409"

        expected_conflicts += 1
      end
      confirmed_counts = [ operations.length ]
      # New completed ink while a previously captured snapshot is already saved.
      # It is sent by the next checkpoint; final unsaved PDF behavior is tested in Chrome.
      operations << stroke(number, operations.length + 1)
    end
    saved = client.remote_draft(assignment)
    expected_pages = JSON.parse(JSON.generate([ { page_number: 1, operations: operations[0...-1] } ]))
    raise "final draft mismatch" unless saved.fetch("pages") == expected_pages && saved.fetch("version") == version

    sleep [ begun + seconds - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0 ].max
    pdf = PDF + "\n% synthetic student #{number}\n"
    attempt = SecureRandom.uuid
    submitted_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = client.submit_unique(assignment, version, attempt, pdf)
    raise "submit failed with HTTP #{response.code}" unless response.code == "200" && JSON.parse(response.body)["submission_token"] == attempt

    submit_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - submitted_at) * 1000).round(1)
    replay = client.submit_unique(assignment, version, attempt, pdf)
    raise "same-attempt retry failed" unless replay.code == "200"

    other = client.submit_unique(assignment, version, SecureRandom.uuid, pdf)
    raise "another attempt was accepted" unless other.code == "409"

    { number: number, requests: requests, submit_ms: submit_ms, version: version,
      expected_conflicts: expected_conflicts + 1, points: operations[0...-1].sum { |operation| operation[:points].length },
      draft_sha256: Digest::SHA256.hexdigest(JSON.generate(expected_pages)), pdf_sha256: Digest::SHA256.hexdigest(pdf) }
  rescue StandardError => error
    # Do not emit request content, cookies, context, credentials or exception messages.
    { number: index + 1, error: error.class.name }
  end
end
30.times { start << true }
results = threads.map { |thread| thread.value }
stop << true
watcher.join(5)
all = results.flat_map { |row| row.fetch(:requests, []) }
latencies = all.map { |row| row[:ms] }.sort
summary = { mode: mode, configured_seconds: seconds, elapsed_seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - begun).round(1),
  students: 30, completed: results.count { |row| !row[:error] }, errors: results.filter_map { |row| row[:error] },
  saves: all.size, save_failures: all.count { |row| row[:status] != 200 },
  p50_ms: latencies[latencies.length / 2], p95_ms: latencies[(latencies.length * 0.95).ceil - 1], max_ms: latencies.max,
  submit_p95_ms: results.filter_map { |row| row[:submit_ms] }.sort[28],
  sent_bytes: all.sum { |row| row[:sent_bytes] }, received_bytes: all.sum { |row| row[:received_bytes] },
  max_rss_kb: samples.filter_map { |sample| sample[:rss_kb] }.max,
  max_db_connections: samples.map { |sample| sample[:connections] }.max,
  max_lock_waiters: samples.map { |sample| sample[:lock_waiters] }.max,
  expected_conflicts: results.sum { |row| row.fetch(:expected_conflicts, 0) },
  points_per_student: results.map { |row| row[:points] } }
File.write("tmp/http_load_#{RUN_ID}_#{mode}_integrity.json", JSON.generate(results.map { |row| row.except(:requests) }))
puts JSON.pretty_generate(summary)
raise "sustained load trial failed" unless summary[:completed] == 30 && summary[:save_failures].zero? && summary[:saves] == 30 * (seconds / 5)
