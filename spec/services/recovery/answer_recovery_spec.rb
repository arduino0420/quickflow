require "rails_helper"
require "timeout"
require_relative "../../support/ai_grading_context"

RSpec.describe Recovery::AnswerRecovery do
  include_context "AI grading records"
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers
  self.use_transactional_tests = false

  let(:service) { described_class.new }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("QUICKFLOW_GRADING_RECOVERY_ENABLED").and_return("true")
    allow(service).to receive(:queue_clear?).and_return(true)
    submission.answer_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")), filename: "answer.pdf", content_type: "application/pdf")
    request = QuestionGenerationRequest.select_for_distribution!(assignment, model: "test-model")
    request.update!(state: "succeeded", claim_token: SecureRandom.uuid)
    create_question(label: "2①").update!(grading_rule: JSON.generate(criteria: "同類項をまとめる。", requires_work: false,
      material_blob_id: assignment.material_file.blob.id))
    submission.update!(status: :failed, extracted_text: JSON.generate(problems: [ problem.merge(question_label: "2(1)") ]),
      processing_claim_stage: "grading", processing_claim_token: SecureRandom.uuid, processing_claimed_at: 5.minutes.ago)
    @fixture_blob_ids = [ submission.answer_file.blob.id, assignment.material_file.blob.id ]
    @threads = []
  end

  after do
    @threads.each { |thread| raise "Recovery worker still alive" unless thread.join(15) }
    AssignmentDeletion.new.call(assignment.reload, teacher: teacher) if Assignment.exists?(assignment.id)
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
    # These two fixtures may deliberately be detached/replaced by an example.
    # Never sweep unrelated unattached blobs in this shared test database.
    @fixture_blob_ids.each do |id|
      blob = ActiveStorage::Blob.find_by(id: id)
      blob.purge if blob && !blob.attachments.exists?
    end
    student.destroy!
    TeacherClassroom.where(classroom: classroom).delete_all
    classroom.destroy!
    teacher.destroy!
    school.destroy!
    clear_enqueued_jobs
  end

  def token
    service.offer(submission.reload, teacher: teacher).fetch(:request_token)
  end

  def retry_answer(request_token = token)
    service.call(submission.id, teacher: teacher, request_token: request_token)
  end

  def missing_reading!
    submission.update!(extracted_text: nil, processing_claim_stage: "reading")
  end

  it "reuses normalized saved readings, records one receipt and commits before dispatch" do
    before_reading = submission.extracted_text
    before_questions = assignment.questions.map(&:attributes)
    pdf = submission.answer_file.blob.attributes
    request_token = token
    expect(AnswerReadingJob).not_to receive(:perform_later)
    expect(QuestionGenerationJob).not_to receive(:perform_later)
    expect(AnswerGradingJob).to receive(:perform_later).once do |row, generation, **options|
      expect(ApplicationRecord.connection.transaction_open?).to be(false)
      expect([ row.id, generation ]).to eq([ submission.id, 1 ])
      expect(options[:admission]).to be_present
      expect(row.reload.grading_recovery_state).to eq("pending")
      true
    end
    expect(retry_answer(request_token)[:result]).to eq("enqueued")
    expect(retry_answer(request_token)[:result]).not_to eq("enqueued")
    expect(submission.reload).to have_attributes(status: "grading", processing_generation: 1,
      grading_recovery_attempts: 1, grading_recovery_state: "enqueued", extracted_text: before_reading)
    expect(submission.answer_file.blob.attributes).to eq(pdf)
    expect(assignment.questions.map(&:attributes)).to eq(before_questions)
    expect(submission.grading_results).to be_empty
  end

  it "dispatches reading only for missing readings with known provenance" do
    missing_reading!
    expect(AnswerGradingJob).not_to receive(:perform_later)
    expect(AnswerReadingJob).to receive(:perform_later).with(have_attributes(id: submission.id), 1, admission: kind_of(String)).once.and_return(true)
    expect(retry_answer[:result]).to eq("enqueued")
    expect(submission.reload.extracted_text).to be_nil
  end

  it "preserves stopped-grading recovery after the queue has been verified" do
    submission.update!(status: :grading, processing_claim_stage: "ready")
    expect(AnswerGradingJob).to receive(:perform_later).once.and_return(true)
    expect(retry_answer[:result]).to eq("enqueued")
    expect(submission.reload.processing_generation).to eq(1)
  end

  [ false, nil, :exception ].each do |outcome|
    it "retains an uncertain receipt and never automatically redispatches for #{outcome.inspect}" do
      request_token = token
      allow(AnswerGradingJob).to receive(:perform_later) { raise "PRIVATE API BODY" if outcome == :exception; outcome }
      allow(Rails.logger).to receive(:warn)
      expect(retry_answer(request_token)).to include(result: "indeterminate", reason_codes: [ "enqueue_not_confirmed" ])
      expect(submission.reload).to have_attributes(status: "grading", grading_recovery_state: "uncertain", grading_recovery_attempts: 1)
      travel 2.minutes do
        expect(service.offer(submission.reload, teacher: teacher)[:reason_codes]).to include("recovery_registration_unknown")
        expect(retry_answer(request_token)[:result]).not_to eq("enqueued")
      end
      expect(AnswerGradingJob).to have_received(:perform_later).once
      expect(Rails.logger).not_to have_received(:warn).with(include("PRIVATE API BODY"))
    end
  end

  it "does not erase a started receipt if enqueue acknowledgement is lost after a worker starts" do
    missing_reading!
    allow(AnswerReadingJob).to receive(:perform_later) do |row, generation, **options|
      claim = SubmissionProcessingClaim.new(row, generation, "reading", admission: options[:admission])
      expect(claim.claim).to be_present
      raise "ack lost"
    end
    expect(retry_answer[:result]).to eq("indeterminate")
    expect(submission.reload.grading_recovery_state).to eq("started")
    expect(submission.processing_claim_stage).to eq("reading")
  end

  it "keeps pending acceptance after a process stop between primary commit and enqueue" do
    request_token = token
    allow(AnswerGradingJob).to receive(:perform_later).and_raise(SystemExit)
    expect { retry_answer(request_token) }.to raise_error(SystemExit)
    expect(submission.reload).to have_attributes(status: "grading", grading_recovery_state: "pending", grading_recovery_attempts: 1)
    travel 2.minutes do
      expect(service.offer(submission.reload, teacher: teacher)[:reason_codes]).to include("recovery_registration_unknown")
      expect(retry_answer(request_token)[:result]).not_to eq("enqueued")
    end
    expect(AnswerGradingJob).to have_received(:perform_later).once
  end

  it "requires a fresh offer after a genuine new failure and enforces the sixty-second interval" do
    request_token = token
    allow(AnswerGradingJob).to receive(:perform_later) do |row, generation, **options|
      claim = SubmissionProcessingClaim.new(row, generation, "grading", admission: options[:admission])
      claim.claim
      claim.fail
      true
    end
    expect(retry_answer(request_token)[:result]).to eq("enqueued")
    expect(submission.reload).to be_failed
    expect(service.offer(submission, teacher: teacher)[:reason_codes]).to include("recovery_cooldown")
    travel 61.seconds do
      expect(retry_answer(request_token)[:result]).not_to eq("enqueued")
      expect(retry_answer[:result]).to eq("enqueued")
    end
    expect(submission.reload.grading_recovery_attempts).to eq(2)
    expect(AnswerGradingJob).to have_received(:perform_later).twice
  end

  it "allows the third receipt but refuses a fourth even after the interval" do
    submission.update!(grading_recovery_attempts: 2, grading_recovery_requested_at: 5.minutes.ago, grading_recovery_state: "started")
    allow(AnswerGradingJob).to receive(:perform_later) do |row, generation, **options|
      claim = SubmissionProcessingClaim.new(row, generation, "grading", admission: options[:admission])
      claim.claim
      claim.fail
      true
    end
    expect(retry_answer[:result]).to eq("enqueued")
    travel 2.minutes do
      expect(service.offer(submission.reload, teacher: teacher)[:reason_codes]).to include("recovery_attempt_limit")
    end
    expect(submission.reload.grading_recovery_attempts).to eq(3)
    expect(AnswerGradingJob).to have_received(:perform_later).once
  end

  it "rejects expired, modified, foreign-teacher and foreign-submission tokens" do
    request_token = token
    expect(retry_answer(request_token + "x")[:reason_codes]).to include("request_invalid_or_expired")
    expect(service.call(submission.id + 1, teacher: teacher, request_token: request_token)[:result]).not_to eq("enqueued")
    impostor = teacher.dup
    impostor.id = teacher.id + 1
    expect(service.call(submission.id, teacher: impostor, request_token: request_token)[:result]).not_to eq("enqueued")
    travel 16.minutes do
      expect(retry_answer(request_token)[:reason_codes]).to include("request_invalid_or_expired")
    end
    expect(submission.reload.processing_generation).to eq(0)
  end

  it "rejects a caller-owned transaction without queue writes" do
    request_token = token
    expect(AnswerGradingJob).not_to receive(:perform_later)
    Submission.transaction { expect(retry_answer(request_token)[:reason_codes]).to include("transaction_open") }
    expect(submission.reload.grading_recovery_attempts).to eq(0)
  end

  it "serializes two overlapping requests across the commit/dispatch gap" do
    request_token = token
    entered = Queue.new
    release = Queue.new
    expect(AnswerGradingJob).to receive(:perform_later).once do
      entered << true
      Timeout.timeout(10) { release.pop }
      true
    end
    first = Thread.new { ApplicationRecord.connection_pool.with_connection { retry_answer(request_token) } }
    @threads << first
    Timeout.timeout(10) { entered.pop }
    expect(retry_answer(request_token)[:result]).not_to eq("enqueued")
    release << true
    expect(first.value[:result]).to eq("enqueued")
    expect(submission.reload.grading_recovery_attempts).to eq(1)
  ensure
    release << true if release
  end

  it "blocks queue presence or uncertainty even for failed submissions" do
    request_token = token
    allow(service).to receive(:queue_clear?).and_return(false)
    expect(retry_answer(request_token)[:reason_codes]).to include("job_present_or_unknown")
    expect(submission.reload.processing_generation).to eq(0)
  end

  [ :completed, :submitted, :results, :teacher_judgment, :bad_json, :missing_pdf, :material_changed,
    :duplicate_reading, :canonical_collision, :missing_label, :unclear, :legacy_reading ].each do |condition|
    it "rejects #{condition} without discarding any data" do
      case condition
      when :completed, :submitted then submission.update!(status: condition)
      when :results, :teacher_judgment
        submission.grading_results.create!(question: assignment.questions.sole, ai_judgment: :correct,
          teacher_judgment: (:incorrect if condition == :teacher_judgment), ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
      when :bad_json then submission.update!(extracted_text: "bad JSON")
      when :missing_pdf then submission.answer_file.detach
      when :material_changed
        assignment.questions.sole.update!(grading_rule: JSON.generate(criteria: "test", requires_work: false, material_blob_id: 0))
      when :duplicate_reading, :canonical_collision
        readings = [ problem.merge(question_label: "2(1)"), problem.merge(question_label: condition == :canonical_collision ? "2①" : "2(1)") ]
        submission.update!(extracted_text: JSON.generate(problems: readings))
      when :missing_label then submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(question_label: "①") ]))
      when :unclear then submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(reading_status: "unclear") ]))
      when :legacy_reading then missing_reading!; submission.update!(processing_claim_token: nil)
      end
      original = submission.reload.attributes
      results = submission.grading_results.map(&:attributes)
      expect(AnswerReadingJob).not_to receive(:perform_later)
      expect(AnswerGradingJob).not_to receive(:perform_later)
      expect(service.offer(submission, teacher: teacher)[:result]).not_to eq("candidate")
      expect(submission.reload.attributes).to eq(original)
      expect(submission.grading_results.map(&:attributes)).to eq(results)
    end
  end

  [ :pending, :running, :failed, :missing ].each do |state|
    it "does not regenerate unready shared answers (#{state})" do
      missing_reading!
      request = assignment.current_question_generation_request
      state == :missing ? assignment.update!(current_question_generation_request: nil) : request.update!(state: state)
      expect(QuestionGenerationJob).not_to receive(:perform_later)
      expect(service.offer(submission, teacher: teacher)[:result]).not_to eq("candidate")
      expect(submission.reload.grading_recovery_attempts).to eq(0)
    end
  end

  it "refuses changed input after a token was issued" do
    request_token = token
    submission.update!(extracted_text: submission.extracted_text.sub("5x", "6x"))
    expect(retry_answer(request_token)[:reason_codes]).to include("state_changed")
    expect(submission.reload.grading_recovery_attempts).to eq(0)
  end

  it "allows only the admitted reading generation and fences stale success, failure and downstream enqueue" do
    missing_reading!
    captured = nil
    allow(AnswerReadingJob).to receive(:perform_later) do |row, generation, **options|
      captured = [ row, generation, options[:admission] ]
      true
    end
    retry_answer
    row, generation, admission = captured
    expect(SubmissionProcessingClaim.new(row, generation, "reading").claim).to be_nil
    claim = SubmissionProcessingClaim.new(row, generation, "reading", admission: admission)
    expect(claim.claim).to be_present
    submission.reload.update!(processing_generation: 2)
    called = false
    claim.finalize { called = true }
    claim.fail
    expect(claim.current?).to be(false)
    expect(called).to be(false)
    expect(submission.reload).to be_grading
    expect(submission.extracted_text).to be_nil
    expect(submission.grading_results).to be_empty
  end

  it "holds recovered reading-to-grading enqueue uncertainty instead of offering another API attempt" do
    missing_reading!
    allow(AnswerReadingJob).to receive(:perform_later).and_return(true)
    retry_answer
    admission = SubmissionProcessingClaim.admission_snapshot(submission.id, 1, stage: "reading")
    claim = SubmissionProcessingClaim.new(submission, 1, "reading", admission: admission)
    claim.claim
    grading_admission = nil
    claim.finalize(admission_stage: "grading") do |current, owner|
      current.update!(processing_claim_stage: "ready", extracted_text: JSON.generate(problems: [ problem.merge(question_label: "2(1)") ]))
      grading_admission = SubmissionProcessingClaim.ready_admission(owner, current, stage: "grading")
    end
    SubmissionProcessingClaim.fail_ready(submission.id, 1, snapshot: grading_admission, stage: "grading")
    expect(submission.reload).to have_attributes(status: "grading", grading_recovery_state: "uncertain")
    travel 2.minutes do
      expect(service.offer(submission.reload, teacher: teacher)[:reason_codes]).to include("recovery_registration_unknown")
    end
    late_claim = SubmissionProcessingClaim.new(submission, 1, "grading", admission: grading_admission)
    expect(late_claim.claim).to be_present
    expect(submission.reload.grading_recovery_state).to eq("started")
  end

  it "rejects a changed PDF between physical verification and locked acceptance" do
    request_token = token
    replaced = false
    allow_any_instance_of(Recovery::RetryEligibility).to receive(:inspect_pdf).and_wrap_original do |method, pdf|
      report = method.call(pdf)
      unless replaced
        replaced = true
        submission.answer_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")), filename: "different.pdf", content_type: "application/pdf")
      end
      report
    end
    expect(AnswerReadingJob).not_to receive(:perform_later)
    expect(AnswerGradingJob).not_to receive(:perform_later)
    expect(retry_answer(request_token)[:reason_codes]).to include("state_changed")
    expect(submission.reload.grading_recovery_attempts).to eq(0)
  end
end
