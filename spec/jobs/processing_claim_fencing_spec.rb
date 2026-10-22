require "rails_helper"
require "timeout"
require_relative "../support/ai_grading_context"

RSpec.describe "AI claim fencing", type: :job do
  include ActiveJob::TestHelper
  include Rails.application.routes.url_helpers
  include_context "AI grading records"
  self.use_transactional_tests = false
  let(:generation_model) { AiClient.model(:question_generation) }

  before do
    @threads = []
    @release = Queue.new
    @entered = Queue.new
    @extra_teachers = []
    submission.answer_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")),
      filename: "answer.pdf", content_type: "application/pdf")
    @id = submission.id
    @assignment_id = assignment.id
  end

  after do
    @threads.size.times { @release << true }
    @threads.each do |thread|
      raise "Live worker prevents cleanup" unless thread.join(10)

      thread.value
    end
    if (item = Assignment.find_by(id: @assignment_id))
      AssignmentDeletion.new.call(item, teacher: item.teacher)
    end
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
    student.destroy!
    TeacherClassroom.where(classroom_id: classroom.id).delete_all
    classroom.destroy!
    @extra_teachers.each(&:destroy!)
    teacher.destroy!
    school.destroy!
    clear_enqueued_jobs
  end

  def run(&block)
    thread = Thread.new { ActiveRecord::Base.connection_pool.with_connection { block.call } }
    @threads << thread
    thread
  end

  def pause_api(outcome)
    expect(ActiveRecord::Base.connection.transaction_open?).to be(false)
    @entered << true
    Timeout.timeout(10) { @release.pop }
    raise "PRIVATE late error" if outcome == :error

    yield
  end

  def change_owner
    other = Teacher.create!(school: school, user_id: "other-#{SecureRandom.hex(4)}", password: "password123")
    @extra_teachers << other
    assignment.update!(teacher: other)
  end

  def mutate(kind)
    submission.reload
    assignment.reload
    case kind
    when :generation then submission.update!(processing_generation: 1)
    when :token then submission.update!(processing_claim_token: SecureRandom.uuid)
    when :stage then submission.update!(processing_claim_stage: "ready")
    when :claimed_at then submission.update!(processing_claimed_at: 1.day.ago)
    when :reading then submission.update!(extracted_text: JSON.generate(problems: [ problem.merge(student_answer: "6x") ]))
    when :answer_blob
      submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nchanged"), filename: "changed.pdf", content_type: "application/pdf")
    when :material_blob
      assignment.material_file.attach(io: StringIO.new("%PDF-1.4\nchanged"), filename: "changed.pdf", content_type: "application/pdf")
    when :questions then assignment.questions.sole.update!(correct_answer: "6x")
    when :question_source then assignment.questions.sole.update!(answer_generation_model: "changed-source")
    when :pointer then assignment.update!(current_question_generation_request: nil)
    when :owner then change_owner
    end
  end

  [ :success, :error ].each do |outcome|
    [ :generation, :token, :stage, :claimed_at, :reading, :answer_blob, :owner ].each do |change|
      it "discards late reading #{outcome} after #{change} changes" do
        submission.update!(extracted_text: nil)
        reader = instance_double(AnswerReader)
        allow(AnswerReader).to receive(:new).and_return(reader)
        expect(reader).to receive(:call).once { pause_api(outcome) { JSON.generate(problems: [ problem ]) } }
        worker = run { AnswerReadingJob.perform_now(Submission.find(@id)) }
        Timeout.timeout(5) { @entered.pop }
        mutate(change)
        expected = submission.reload.attributes
        @release << true
        expect(worker.join(10)).to be_present
        worker.value
        expect(submission.reload.attributes).to eq(expected)
        expect(submission.grading_results).to be_empty
        expect(enqueued_jobs.none? { |job| job[:job] == AnswerGradingJob }).to be(true)
      end
    end

    [ :generation, :token, :stage, :claimed_at, :reading, :answer_blob, :material_blob,
      :questions, :question_source, :pointer, :owner ].each do |change|
      it "discards late grading #{outcome} after #{change} changes" do
        question = create_question
        grader = instance_double(AnswerGrader)
        allow(AnswerGrader).to receive(:new).and_return(grader)
        expect(grader).to receive(:call).once do
          pause_api(outcome) do
            [ { question: question, student_answer: "5x", ai_judgment: "correct",
              ai_model_name: "test", prompt_version: "v1", graded_at: Time.current } ]
          end
        end
        worker = run { AnswerGradingJob.perform_now(Submission.find(@id)) }
        Timeout.timeout(5) { @entered.pop }
        mutate(change)
        expected = submission.reload.attributes
        @release << true
        expect(worker.join(10)).to be_present
        worker.value
        expect(submission.reload.attributes).to eq(expected)
        expect(submission.grading_results).to be_empty
      end
    end

    [ :token, :state, :pointer, :owner, :material_blob, :questions ].each do |change|
      it "discards late generation #{outcome} after #{change} changes" do
        request_id = assignment.current_question_generation_request_id
        allow(AiClient).to receive(:build).and_return(client)
        allow(files).to receive(:create).and_return(double(id: "captured-material"))
        expect(responses).to receive(:create).once do
          pause_api(outcome) do
            ai_response(questions: [ { question_label: "1", question_text: "3x+2x", correct_answer: "5x",
              grading_rule: "同類項", requires_work: false } ])
          end
        end
        blob_id = assignment.material_file.blob.id
        worker = run { QuestionGenerationJob.perform_now(Assignment.find(@assignment_id), blob_id, request_id: request_id) }
        Timeout.timeout(5) { @entered.pop }
        if change == :token
          QuestionGenerationRequest.find(request_id).update!(claim_token: SecureRandom.uuid)
        elsif change == :state
          QuestionGenerationRequest.find(request_id).update!(state: "failed")
        elsif change == :questions
          create_question
        else
          mutate(change)
        end
        expected_questions = assignment.questions.order(:id).map(&:attributes)
        expected_request = QuestionGenerationRequest.find(request_id).attributes
        expected_submission = submission.reload.attributes
        @release << true
        expect(worker.join(10)).to be_present
        worker.value
        expect(QuestionGenerationRequest.find(request_id).attributes).to eq(expected_request)
        expect(submission.reload.attributes).to eq(expected_submission)
        expect(assignment.questions.order(:id).map(&:attributes)).to eq(expected_questions)
      end
    end
  end

  it "saves a paused reading after generation finishes without invalidating unrelated reading inputs" do
    submission.update!(extracted_text: nil)
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    expect(reader).to receive(:call).once { pause_api(:success) { JSON.generate(problems: [ problem ]) } }
    worker = run { AnswerReadingJob.perform_now(Submission.find(@id)) }
    Timeout.timeout(5) { @entered.pop }
    allow(AiClient).to receive(:build).and_return(client)
    allow(files).to receive(:create).and_return(double(id: "material"))
    allow(responses).to receive(:create).and_return(ai_response(questions: [ {
      question_label: "1(1)", question_text: "3x+2x", correct_answer: "5x", grading_rule: "同類項", requires_work: false
    } ]))
    QuestionGenerationJob.perform_now(assignment, assignment.material_file.blob.id,
      request_id: assignment.current_question_generation_request_id)
    expect(submission.reload.processing_claim_stage).to eq("reading")
    expect(assignment.questions.count).to eq(1)
    @release << true
    expect(worker.join(10)).to be_present
    worker.value
    expect(submission.reload.extracted_text).to be_present
    expect(submission.processing_claim_stage).to eq("ready")
    expect(enqueued_jobs.count { |job| job[:job] == AnswerGradingJob }).to eq(1)
  end

  [ :generation, :recovery ].each do |source|
    it "fences delayed #{source} enqueue rejection after grading has claimed" do
      question = create_question
      question.update!(grading_rule: JSON.generate(criteria: "同類項", requires_work: false,
        material_blob_id: assignment.material_file.blob.id))
      grader = instance_double(AnswerGrader)
      allow(AnswerGrader).to receive(:new).and_return(grader)
      expect(grader).to receive(:call).once do
        pause_api(:success) do
          [ { question: question, student_answer: "5x", ai_judgment: "correct",
            ai_model_name: "test", prompt_version: "v1", graded_at: Time.current } ]
        end
      end
      worker = nil
      allow(AnswerGradingJob).to receive(:perform_later) do
        worker = run { AnswerGradingJob.perform_now(Submission.find(@id), source == :recovery ? 1 : 0) }
        Timeout.timeout(5) { @entered.pop }
        false
      end
      if source == :recovery
        submission.update!(status: :failed)
        expect(Recovery::GradingRecovery.new.call(@id)[:reason_codes]).to eq([ "enqueue_failed" ])
      else
        request = assignment.current_question_generation_request
        request.update!(state: "succeeded", claim_token: SecureRandom.uuid)
        QuestionGenerationJob.perform_now(assignment, assignment.material_file.blob.id, request_id: request.id)
      end
      expect(submission.reload).to be_grading
      expect(submission.processing_claim_stage).to eq("grading")
      @release << true
      expect(worker.join(10)).to be_present
      worker.value
      expect(submission.reload).to be_completed
    end
  end

  it "fences a delayed initial enqueue rejection after reading has claimed" do
    submission.answer_file.purge
    submission.destroy!
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    expect(reader).to receive(:call).once { pause_api(:success) { JSON.generate(problems: [ problem ]) } }
    worker = nil
    allow(AnswerReadingJob).to receive(:perform_later) do |current|
      @id = current.id
      worker = run { AnswerReadingJob.perform_now(Submission.find(@id)) }
      Timeout.timeout(5) { @entered.pop }
      false
    end
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.post student_login_path, params: { student_session: { school_code: school.school_code,
      grade: 1, class_number: 1, attendance_number: student.attendance_number, password: "password123" } }
    session.post student_assignment_submission_path(assignment), params: { submission: {
      answer_file: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/material.pdf"), "application/pdf")
    } }
    expect(session.response.status).to eq(303)
    expect(Submission.find(@id).processing_claim_stage).to eq("reading")
    expect(Submission.find(@id)).to be_grading
    @release << true
    expect(worker.join(10)).to be_present
    worker.value
    expect(Submission.find(@id).extracted_text).to be_present
    expect(Submission.find(@id)).to be_grading
  end

  it "keeps unknown legacy and lost old claims closed without age takeover" do
    submission.update!(processing_claim_stage: nil)
    expect(AnswerReader).not_to receive(:new)
    expect(AnswerGrader).not_to receive(:new)
    AnswerReadingJob.perform_now(submission)
    AnswerGradingJob.perform_now(submission)
    submission.update!(processing_claim_stage: "reading", processing_claim_token: "lost", processing_claimed_at: 10.days.ago)
    AnswerReadingJob.perform_now(submission)
    expect(submission.reload.processing_claim_token).to eq("lost")
    expect(submission).to be_submitted
  end

  it "allows unrelated timestamps and scoring changes while grading the captured inputs" do
    question = create_question
    grader = instance_double(AnswerGrader)
    allow(AnswerGrader).to receive(:new).and_return(grader)
    expect(grader).to receive(:call).once do
      pause_api(:success) do
        [ { question: question, student_answer: "5x", ai_judgment: "correct",
          ai_model_name: "test", prompt_version: "v1", graded_at: Time.current } ]
      end
    end
    worker = run { AnswerGradingJob.perform_now(Submission.find(@id)) }
    Timeout.timeout(5) { @entered.pop }
    assignment.update!(title: "Renamed", point_per_question: 10)
    submission.touch
    @release << true
    expect(worker.join(10)).to be_present
    worker.value
    expect(submission.reload).to be_completed
    expect(submission.score).to eq(10)
  end

  it "fences a stopped worker through eligible explicit grading recovery" do
    question = create_question
    question.update!(grading_rule: JSON.generate(criteria: "同類項", requires_work: false,
      material_blob_id: assignment.material_file.blob.id))
    grader = instance_double(AnswerGrader)
    allow(AnswerGrader).to receive(:new).and_return(grader)
    expect(grader).to receive(:call).once do
      pause_api(:success) do
        [ { question: question, student_answer: "5x", ai_judgment: "correct",
          ai_model_name: "test", prompt_version: "v1", graded_at: Time.current } ]
      end
    end
    worker = run { AnswerGradingJob.perform_now(Submission.find(@id)) }
    Timeout.timeout(5) { @entered.pop }
    recovery = Recovery::GradingRecovery.new
    allow(recovery).to receive(:queue_clear?).and_return(true)
    allow(AnswerGradingJob).to receive(:perform_later).and_return(true)
    expect(recovery.call(@id, interrupted_generation: 0)[:result]).to eq("enqueued")
    expected = submission.reload.attributes
    expect(submission.processing_generation).to eq(1)
    expect(submission.processing_claim_stage).to eq("ready")
    @release << true
    expect(worker.join(10)).to be_present
    worker.value
    expect(submission.reload.attributes).to eq(expected)
    expect(submission.grading_results).to be_empty
  end
end
