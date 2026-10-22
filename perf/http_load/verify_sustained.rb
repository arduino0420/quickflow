require "json"
require "digest"

raise "test only" unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database == "quickflow_test"
run_id = ENV.fetch("QUICKFLOW_HTTP_LOAD_RUN_ID")
fixture = JSON.parse(File.read(Rails.root.join("tmp", "http_load_fixture_#{run_id}.json")))
jobs = File.readlines(Rails.root.join("tmp", "http_load_jobs_#{run_id}.jsonl")).map { |line| JSON.parse(line) }
modes = ENV.fetch("QUICKFLOW_SUSTAINED_MODES", "sustained_legacy sustained_append").split
raise "invalid modes" if modes.empty? || (modes - %w[sustained_legacy sustained_ack sustained_append]).any?

results = modes.uniq.to_h do |mode|
  assignment_id = fixture.fetch("assignments").fetch(mode)
  expected = JSON.parse(File.read(Rails.root.join("tmp", "http_load_#{run_id}_#{mode}_integrity.json")))
  raise "client errors" unless expected.size == 30 && expected.none? { |row| row["error"] }

  expected.each do |row|
    student_id = fixture.fetch("student_ids").fetch(row.fetch("number") - 1)
    draft = AnswerDraft.find_by!(student_id: student_id, assignment_id: assignment_id)
    # JSONB may reorder object keys; compare the same canonical structure as the source fixture.
    actual = draft.page_data.map do |page|
      { "page_number" => page.fetch("page_number"), "operations" => page.fetch("operations").map do |operation|
        operation.slice("id", "tool", "color", "width", "points")
      end }
    end
    raise "stored draft differs" unless Digest::SHA256.hexdigest(JSON.generate(actual)) == row.fetch("draft_sha256") && draft.lock_version == row.fetch("version")

    submission = Submission.find_by!(student_id: student_id, assignment_id: assignment_id)
    raise "mixed or missing PDF" unless Digest::SHA256.hexdigest(submission.answer_file.download) == row.fetch("pdf_sha256")
    raise "wrong reading job count" unless jobs.count { |job| job["submission_id"] == submission.id && job["job_type"] == "AnswerReadingJob" } == 1
    raise "AI unexpectedly executed" unless submission.grading_results.empty?
  end
  raise "wrong counts" unless AnswerDraft.where(assignment_id: assignment_id).count == 30 && Submission.where(assignment_id: assignment_id).count == 30

  [ mode, { drafts: 30, submissions: 30, exact_drafts: 30, distinct_pdfs: 30, reading_jobs: 30, grading_results: 0 } ]
end
puts JSON.pretty_generate(results)
