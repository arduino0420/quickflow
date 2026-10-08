require "rails_helper"
require "timeout"
require_relative "../support/ai_grading_context"

RSpec.describe "Concurrent AI processing", type: :job do
  include_context "AI grading records"
  self.use_transactional_tests = false

  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_cache
  end

  # These examples need committed records visible to separate database connections.
  # Only records created by this example are removed, in foreign-key order.
  after do
    GradingResult.where(submission_id: Submission.where(assignment_id: assignment.id).select(:id)).delete_all
    Submission.where(assignment_id: assignment.id).find_each do |item|
      item.answer_file.purge
      item.destroy!
    end
    Question.where(assignment_id: assignment.id).delete_all
    assignment.material_file.purge
    assignment.destroy!
    @other_student&.destroy!
    student.destroy!
    classroom.destroy!
    teacher.destroy!
    school.destroy!
  end

  it "commits another student's PDF submission while question generation is still waiting" do
    assignment_id = submission.assignment_id
    @other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    entered = Queue.new
    release = Queue.new
    allow(AiClient).to receive(:build).and_return(client)
    allow(files).to receive(:create).and_return(double(id: "file-material"))
    expect(responses).to receive(:create).once do
      entered << true
      Timeout.timeout(10) { release.pop }
      ai_response(questions: [ { question_label: "1(1)", question_text: problem[:question_text], correct_answer: "5x",
        grading_rule: "同類項をまとめる。", requires_work: false } ])
    end
    generation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        QuestionGenerator.new.call(Assignment.find(assignment_id))
      end
    end
    Timeout.timeout(10) { entered.pop }

    # This separate connection uses the same INSERT and attachment save as the controller.
    other_submission = Submission.transaction do
      ActiveRecord::Base.connection.execute("SET LOCAL lock_timeout = '2s'")
      ActiveRecord::Base.connection.execute("SET LOCAL statement_timeout = '3s'")
      Submission.create!(assignment_id: assignment_id, student: @other_student, submitted_at: Time.current,
        answer_file: { io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
          filename: "answer.pdf", content_type: "application/pdf" })
    end
    expect(generation).to be_alive
    expect(other_submission.reload).to be_persisted
    expect(other_submission.answer_file).to be_attached
    expect(assignment.questions).to be_empty
    release << true
    expect(generation.join(10)).to be_present
    expect(generation.value.size).to eq(1)
    expect(files).to have_received(:create).once
  ensure
    release << true if release
    generation&.join(10)
  end

  def overlap(first, second, entered, release)
    threads = [ Thread.new { ActiveRecord::Base.connection_pool.with_connection { first.call } } ]
    Timeout.timeout(10) { entered.pop }
    backend = Queue.new
    threads << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        backend << connection.select_value("SELECT pg_backend_pid()")
        second.call
      end
    end
    Timeout.timeout(10) do
      pid = Integer(backend.pop)
      loop do
        break if ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{pid}))").positive?

        sleep 0.01
      end
    end
    release << true
    threads.each { |thread| raise "Concurrent job did not finish" unless thread.join(10) }
    threads.map(&:value)
  ensure
    release << true
    threads&.each { |thread| thread.join(10) }
  end

  it "makes only one generation request when two delivery generation jobs run together" do
    assignment_id = submission.assignment_id
    blob_id = assignment.material_file.blob.id
    entered = Queue.new
    release = Queue.new
    allow(AiClient).to receive(:build).and_return(client)
    allow(files).to receive(:create).and_return(double(id: "file-material"))
    expect(responses).to receive(:create).once do
      entered << true
      release.pop
      ai_response(questions: [ { question_label: "1(1)", question_text: problem[:question_text], correct_answer: "5x",
        grading_rule: "同類項をまとめる。", requires_work: false } ])
    end
    overlap(
      -> { QuestionGenerationJob.perform_now(Assignment.find(assignment_id), blob_id) },
      -> { QuestionGenerationJob.perform_now(Assignment.find(assignment_id), blob_id) }, entered, release)
    expect(assignment.questions.count).to eq(1)
    expect(files).to have_received(:create).once
  end

  it "makes only one grading request when the same submission's job runs twice" do
    question = create_question
    submission_id = submission.id
    entered = Queue.new
    release = Queue.new
    allow(AiClient).to receive(:build).and_return(client)
    expect(responses).to receive(:create).once do
      entered << true
      release.pop
      ai_response(results: [ judgment(question) ])
    end
    overlap(
      -> { AnswerGradingJob.perform_now(Submission.find(submission_id)) },
      -> { AnswerGradingJob.perform_now(Submission.find(submission_id)) }, entered, release)
    expect(submission.reload).to be_completed
    expect(submission.grading_results.count).to eq(1)
  end

  it "does not repeat a timed-out generation request for a simultaneous submission" do
    assignment_id = submission.assignment_id
    entered = Queue.new
    release = Queue.new
    allow(AiClient).to receive(:build).and_return(client)
    allow(files).to receive(:create).and_return(double(id: "file-material"))
    expect(responses).to receive(:create).once do
      entered << true
      release.pop
      raise OpenAI::Errors::APITimeoutError.new(url: URI("https://example.invalid"), message: "Timed out")
    end
    attempt = lambda do
      QuestionGenerator.new.call(Assignment.find(assignment_id))
    rescue StandardError => error
      error.message
    end
    results = overlap(attempt, attempt, entered, release)
    expect(results.first).to eq("Timed out")
    expect(results.last).to include("automatic reattempt is disabled")
    expect(assignment.questions).to be_empty
    expect(files).to have_received(:create).once
  end

  it "reads a submission only once when two reading jobs run together" do
    submission.update!(extracted_text: nil)
    submission_id = submission.id
    entered = Queue.new
    release = Queue.new
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    expect(reader).to receive(:call).once do
      entered << true
      release.pop
      JSON.generate(problems: [ problem ])
    end
    overlap(
      -> { AnswerReadingJob.perform_now(Submission.find(submission_id)) },
      -> { AnswerReadingJob.perform_now(Submission.find(submission_id)) }, entered, release)
    expect(submission.reload.extracted_text).to be_present
    expect(submission).to be_grading
  end

  it "does not repeat a rejected grading registration for concurrent reading jobs" do
    submission_id = submission.id
    original_reading = submission.extracted_text
    entered = Queue.new
    release = Queue.new
    expect(AnswerReader).not_to receive(:new)
    expect(AnswerGradingJob).to receive(:perform_later).once do
      entered << true
      Timeout.timeout(10) { release.pop }
      false
    end
    overlap(
      -> { AnswerReadingJob.perform_now(Submission.find(submission_id)) },
      -> { AnswerReadingJob.perform_now(Submission.find(submission_id)) }, entered, release)
    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to eq(original_reading)
    expect(submission.grading_results).to be_empty
  end
end
