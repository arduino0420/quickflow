require "rails_helper"
require "timeout"
require_relative "../support/ai_grading_context"

RSpec.describe "Teacher grading recovery concurrency", type: :request do
  include ActiveJob::TestHelper
  include_context "AI grading records"
  self.use_transactional_tests = false

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("QUICKFLOW_GRADING_RECOVERY_ENABLED").and_return("true")
    submission.answer_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")),
      filename: "answer.pdf", content_type: "application/pdf")
    question = create_question
    question.update!(grading_rule: JSON.generate(criteria: "同類項をまとめる。", requires_work: false,
      material_blob_id: assignment.material_file.blob.id))
    @assignment_id = assignment.id
    @submission_id = submission.id
    @threads = []
  end

  after do
    @threads.each { |thread| raise "Worker did not finish" unless thread.join(10) }
    item = Assignment.find_by(id: @assignment_id)
    AssignmentDeletion.new.call(item, teacher: teacher) if item
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
    student.destroy!
    TeacherClassroom.where(classroom_id: classroom.id).delete_all
    classroom.destroy!
    teacher.destroy!
    school.destroy!
  ensure
    clear_enqueued_jobs
  end

  def teacher_session
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.post(login_path, params: { session: { user_id: teacher.user_id, password: "password123" } })
    session
  end

  def resume_path
    resume_grading_assignment_submission_path(@assignment_id, @submission_id)
  end

  def run_thread(&block)
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { block.call }
    end
    @threads << thread
    thread
  end

  it "accepts only one of two overlapping teacher POSTs" do
    submission.update!(status: :failed)
    first = teacher_session
    second = teacher_session
    entered = Queue.new
    release = Queue.new
    expect(AnswerGradingJob).to receive(:perform_later).once do
      entered << true
      Timeout.timeout(10) { release.pop }
      true
    end

    request = run_thread { first.post(resume_path) }
    Timeout.timeout(10) { entered.pop }
    second.post(resume_path)
    expect(second.response.status).to eq(303)
    expect(second.response.location).to end_with(assignment_submission_path(@assignment_id, @submission_id))
    expect(submission.reload.processing_generation).to eq(1)
    release << true
    expect(request.join(10)).to be_present
    expect(request.value).to eq(303)
    expect(submission.reload).to be_grading
  ensure
    release << true if release
  end

  it "refuses a POST while the normal grading job is running" do
    submission.update!(status: :grading)
    session = teacher_session
    entered = Queue.new
    release = Queue.new
    grader = instance_double(AnswerGrader)
    allow(AnswerGrader).to receive(:new).and_return(grader)
    expect(grader).to receive(:call).once do
      entered << true
      Timeout.timeout(10) { release.pop }
      [ judgment(assignment.questions.sole).merge(ai_model_name: "test", prompt_version: "v1", graded_at: Time.current) ]
    end

    worker = run_thread { AnswerGradingJob.perform_now(Submission.find(@submission_id)) }
    Timeout.timeout(10) { entered.pop }
    expect(AnswerGradingJob).not_to receive(:perform_later)
    session.post(resume_path)
    expect(session.response.status).to eq(303)
    expect(session.response.location).to end_with(assignment_submission_path(@assignment_id, @submission_id))
    expect(submission.reload.processing_generation).to eq(0)
    release << true
    expect(worker.join(10)).to be_present
    expect(submission.reload).to be_completed
    expect(submission.grading_results.count).to eq(1)
  ensure
    release << true if release
  end

  it "does not enqueue when deletion wins during PDF verification" do
    submission.update!(status: :failed)
    session = teacher_session
    entered = Queue.new
    release = Queue.new
    paused = false
    allow_any_instance_of(Recovery::GradingEligibility).to receive(:inspect_pdf).and_wrap_original do |method, pdf|
      result = method.call(pdf)
      unless paused
        paused = true
        entered << true
        Timeout.timeout(10) { release.pop }
      end
      result
    end
    expect(AnswerGradingJob).not_to receive(:perform_later)

    request = run_thread { session.post(resume_path) }
    Timeout.timeout(10) { entered.pop }
    expect(AssignmentDeletion.new.call(Assignment.find(@assignment_id), teacher: teacher)).to eq(:deleted)
    release << true
    expect(request.join(10)).to be_present
    expect(Submission.exists?(@submission_id)).to be(false)
    expect(GradingResult.where(submission_id: @submission_id)).to be_empty
  ensure
    release << true if release
  end
end
