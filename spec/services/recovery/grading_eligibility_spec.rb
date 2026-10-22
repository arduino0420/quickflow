require "rails_helper"
require_relative "../../support/ai_grading_context"

RSpec.describe Recovery::GradingEligibility do
  include_context "AI grading records"

  let(:service) { described_class.new }

  before do
    submission.answer_file.attach(
      io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      filename: "private-answer.pdf", content_type: "application/pdf"
    )
    submission.update!(status: :failed)
    saved_question
  end

  def saved_question(position: 1, label: "1(1)", answer: "5x", requires_work: false)
    item = create_question(position: position, label: label, answer: answer, requires_work: requires_work)
    item.update!(grading_rule: JSON.generate(criteria: "同類項をまとめる。", requires_work: requires_work,
      material_blob_id: assignment.material_file.blob.id))
    item
  end

  def replace_reading(problems)
    submission.update!(extracted_text: JSON.generate(problems: problems))
  end

  def report
    service.call(submission)
  end

  it "marks a structurally valid failed answer as a candidate after verifying both stored PDFs" do
    expect(report).to eq(result: "candidate", reason_codes: [ "all_conditions_met_at_observation" ])
  end

  it "rejects every status other than failed" do
    submission.update!(status: :grading)
    expect(report).to include(result: "ineligible")
    expect(report[:reason_codes]).to include("status_not_failed")
  end

  it "rejects malformed or empty reading JSON" do
    submission.update!(extracted_text: "not-json")
    expect(report[:reason_codes]).to include("reading_json_invalid")
  end

  it "rejects a numeric final answer through the existing reading parser" do
    numeric_problem = problem.merge(student_answer: 123)
    expect { AnswerGrader.reading_problems(JSON.generate(problems: [ numeric_problem ])) }
      .to raise_error(RuntimeError, "Invalid answer reading result")

    submission.update!(extracted_text: JSON.generate(problems: [ numeric_problem ]))
    expect(report[:reason_codes]).to include("reading_json_invalid")
    expect(report[:result]).to eq("ineligible")
  end

  it "rejects invalid submission identifiers without querying the database" do
    expect(Submission).not_to receive(:find_by)
    expect(service.call("123invalid")).to eq(result: "ineligible", reason_codes: [ "invalid_submission_id" ])
    expect(service.call("9" * 40)).to eq(result: "ineligible", reason_codes: [ "invalid_submission_id" ])
  end

  it "rejects duplicate, missing, and extra question labels" do
    duplicate = [ problem, problem ]
    replace_reading(duplicate)
    expect(report[:reason_codes]).to include("reading_question_label_duplicate")

    replace_reading([])
    expect(report[:reason_codes]).to include("reading_json_invalid")

    replace_reading([ problem.merge(question_label: "extra") ])
    expect(report[:reason_codes]).to include("reading_question_labels_mismatch")

    saved_question(position: 2, label: "1(2)")
    expect(report[:reason_codes]).to include("reading_question_labels_mismatch")
  end

  it "requires readable answers to be present and blank answers to be absent" do
    replace_reading([ problem.merge(student_answer: nil) ])
    expect(report[:reason_codes]).to include("reading_state_invalid")

    replace_reading([ problem.merge(reading_status: "blank", student_answer: "5x") ])
    expect(report[:reason_codes]).to include("reading_state_invalid")

    replace_reading([ problem.merge(reading_status: "blank", student_answer: "   ") ])
    expect(report[:reason_codes]).to include("reading_state_invalid")

    replace_reading([ problem.merge(reading_status: "blank", student_answer: nil) ])
    expect(report[:result]).to eq("candidate")

    replace_reading([ problem.merge(reading_status: "unclear", student_answer: nil) ])
    expect(report[:reason_codes]).to include("reading_state_invalid")
  end

  it "rejects invalid saved questions and malformed grading rules" do
    Question.find_by!(assignment: assignment).update_columns(question_text: "")
    expect(report[:reason_codes]).to include("saved_questions_invalid")
  end

  it "requires every saved grading rule to identify the current material Blob" do
    question = Question.find_by!(assignment: assignment)
    question.update!(grading_rule: JSON.generate(criteria: "規則", requires_work: false))
    expect(report[:reason_codes]).to include("material_blob_id_missing")

    question.update!(grading_rule: JSON.generate(criteria: "規則", requires_work: false, material_blob_id: -1))
    expect(report[:reason_codes]).to include("material_blob_mismatch")
  end

  it "rejects any existing grading result and explicitly identifies teacher judgments" do
    question = Question.find_by!(assignment: assignment)
    submission.grading_results.create!(question: question, ai_judgment: :correct,
      ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
    expect(report[:reason_codes]).to include("grading_results_present")

    result = submission.grading_results.first
    result.update!(teacher_judgment: :incorrect)
    expect(report[:reason_codes]).to include("grading_results_present", "teacher_judgment_present")
  end

  it "rejects a missing answer attachment" do
    submission.answer_file.detach
    expect(report[:reason_codes]).to include("answer_attachment_missing")
  end

  it "rejects a missing material attachment" do
    assignment.material_file.detach
    expect(report[:reason_codes]).to include("material_attachment_missing")
  end

  it "rejects missing stored objects and checksum mismatches" do
    allow_any_instance_of(ActiveStorage::Blob).to receive(:open).and_raise(ActiveStorage::FileNotFoundError)
    expect(report[:reason_codes]).to include("pdf_object_missing")

    allow_any_instance_of(ActiveStorage::Blob).to receive(:open).and_raise(ActiveStorage::IntegrityError)
    expect(report[:reason_codes]).to include("pdf_checksum_mismatch")
  end

  it "rejects content that is not actually a PDF despite PDF metadata" do
    submission.answer_file.attach(io: StringIO.new("not a PDF"), filename: "answer.pdf", content_type: "application/pdf")
    expect(report[:reason_codes]).to include("pdf_content_invalid")
  end

  it "rejects incomplete or non-PDF Blob metadata" do
    submission.answer_file.blob.update!(content_type: "text/plain")
    expect(report[:reason_codes]).to include("pdf_metadata_invalid")
  end

  it "returns indeterminate when the storage service cannot be reached" do
    allow_any_instance_of(ActiveStorage::Blob).to receive(:open).and_raise(IOError, "private storage detail")
    expect(report).to eq(result: "indeterminate", reason_codes: [ "pdf_storage_unavailable" ])
    expect(report.to_json).not_to include("private storage detail")
  end

  it "uses a non-blocking advisory lock compatible with the lifecycle session lock" do
    key = "quickflow-assignment-lifecycle:#{assignment.id}"
    locked = Queue.new
    release = Queue.new
    holder = Thread.new do
      connection = nil
      begin
        config = ActiveRecord::Base.connection_db_config.configuration_hash
        connection = PG.connect(host: config[:host], port: config[:port], dbname: config[:database],
          user: config[:username], password: config[:password])
        connection.exec_params("SELECT pg_advisory_lock(hashtextextended($1, 0))", [ key ]).clear
        locked << connection.backend_pid
        release.pop
        connection.exec_params("SELECT pg_advisory_unlock(hashtextextended($1, 0))", [ key ]).clear
      end
    rescue StandardError => error
      locked << error
    ensure
      connection&.close
    end

    lock_holder_pid = locked.pop
    raise lock_holder_pid if lock_holder_pid.is_a?(StandardError)
    expect(lock_holder_pid).not_to eq(ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()").to_i)
    expect(report).to eq(result: "indeterminate", reason_codes: [ "assignment_lifecycle_lock_busy" ])
  ensure
    release << true if release
    holder&.join
  end

  it "returns indeterminate instead of waiting when an assignment row lock is unavailable" do
    allow(Assignment).to receive(:lock).with("FOR NO KEY UPDATE NOWAIT")
      .and_raise(PG::LockNotAvailable, "private database detail")
    expect(report).to eq(result: "indeterminate", reason_codes: [ "database_lock_unavailable" ])
  end

  it "returns indeterminate without exposing details when the database connection fails during snapshot reads" do
    allow(Submission).to receive(:find_by).and_raise(ActiveRecord::ConnectionFailed, "private database connection details")

    expect(report).to eq(result: "indeterminate", reason_codes: [ "database_unavailable" ])
    expect(report.to_json).not_to include("private database connection details")
  end

  [ ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked ].each do |database_error|
    it "returns indeterminate for #{database_error} during snapshot reads" do
      allow(Submission).to receive(:find_by).and_raise(database_error, "private database error details")

      expect(report).to eq(result: "indeterminate", reason_codes: [ "database_lock_unavailable" ])
      expect(report.to_json).not_to include("private database error details")
    end
  end

  it "returns indeterminate when the database connection fails during the final locked recheck" do
    allow(service).to receive(:verify_locked_snapshot)
      .and_raise(ActiveRecord::ConnectionFailed, "private database connection details")

    expect(report).to eq(result: "indeterminate", reason_codes: [ "database_unavailable" ])
    expect(report.to_json).not_to include("private database connection details")
  end

  it "returns indeterminate when relevant state changes between PDF reads and the locked recheck" do
    calls = 0
    allow(service).to receive(:inspect_pdf).and_wrap_original do |original, pdf|
      outcome = original.call(pdf)
      calls += 1
      submission.update!(processing_generation: 1) if calls == 1
      outcome
    end

    expect(report).to eq(result: "indeterminate", reason_codes: [ "state_changed" ])
  end

  it "returns indeterminate when a saved question changes during PDF verification" do
    question = Question.find_by!(assignment: assignment)
    calls = 0
    allow(service).to receive(:inspect_pdf).and_wrap_original do |original, pdf|
      outcome = original.call(pdf)
      calls += 1
      question.update!(correct_answer: "6x") if calls == 1
      outcome
    end

    expect(report).to eq(result: "indeterminate", reason_codes: [ "state_changed" ])
  end

  it "does not write DB data, change cache, enqueue Jobs, or construct an AI client" do
    models = [ Submission, Assignment, Question, GradingResult, ActiveStorage::Attachment, ActiveStorage::Blob ]
    before_data = models.map { |model| model.order(:id).map(&:attributes) }
    expect(OpenAI::Client).not_to receive(:new)
    expect(AiClient).not_to receive(:build)
    [ AnswerReadingJob, AnswerGradingJob, QuestionGenerationJob ].each do |job|
      expect(job).not_to receive(:perform_later)
    end
    expect(Rails.cache).not_to receive(:read)
    expect(Rails.cache).not_to receive(:write)
    expect(Rails.cache).not_to receive(:delete)
    statements = []
    observer = ->(event) { statements << event.payload[:sql] }

    ActiveSupport::Notifications.subscribed(observer, "sql.active_record") { report }

    expect(statements.grep(/\A\s*(INSERT|UPDATE|DELETE|MERGE|CREATE|ALTER|DROP|TRUNCATE)\b/i)).to be_empty
    expect(models.map { |model| model.order(:id).map(&:attributes) }).to eq(before_data)
    expect(submission.reload).to be_failed
    expect(submission.reload.processing_generation).to eq(0)
  end
end
