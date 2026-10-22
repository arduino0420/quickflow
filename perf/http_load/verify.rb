require "json"
require "digest"

run_id = ENV.fetch("QUICKFLOW_HTTP_LOAD_RUN_ID")
fixture = JSON.parse(File.read(Rails.root.join("tmp", "http_load_fixture_#{run_id}.json")))
jobs_path = Rails.root.join("tmp", "http_load_jobs_#{run_id}.jsonl")
jobs = File.exist?(jobs_path) ? File.readlines(jobs_path).map { |line| JSON.parse(line) } : []
expected = Digest::SHA256.file(Rails.root.join("spec/fixtures/files/material.pdf")).hexdigest
result = fixture.fetch("assignments").transform_values do |assignment_id|
  submissions = Submission.where(assignment_id: assignment_id).includes(answer_file_attachment: :blob).to_a
  ids = submissions.map(&:id)
  relevant_jobs = jobs.select { |job| ids.include?(job["submission_id"]) }
  { submissions: submissions.size, unique_students: submissions.map(&:student_id).uniq.size,
    readable_pdfs: submissions.count { |submission| submission.answer_file.attached? &&
      Digest::SHA256.hexdigest(submission.answer_file.download) == expected },
    generation_zero: submissions.count { |submission| submission.processing_generation == 0 },
    grading_results: GradingResult.where(submission_id: ids).count,
    reading_jobs: relevant_jobs.count { |job| job["job_type"] == "AnswerReadingJob" },
    other_jobs: relevant_jobs.count { |job| job["job_type"] != "AnswerReadingJob" },
    distinct_job_submissions: relevant_jobs.map { |job| job["submission_id"] }.uniq.size,
    distinct_job_ids: relevant_jobs.map { |job| job["job_id"] }.uniq.size }
end
puts JSON.generate(result)
