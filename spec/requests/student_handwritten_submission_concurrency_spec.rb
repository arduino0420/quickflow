require "rails_helper"
require "timeout"

RSpec.describe "Concurrent handwritten submission", type: :request do
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  before do
    raise "test database required" unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database == "quickflow_test"

    @threads = []
    @release = Queue.new
    @entered = Queue.new
    @school = School.create!(school_code: "INK#{SecureRandom.hex(4)}")
    @teacher = Teacher.create!(school: @school, user_id: "ink#{SecureRandom.hex(4)}", password: "password123")
    @classroom = Classroom.create!(school: @school, grade: 1, class_number: 1)
    @student = Student.create!(classroom: @classroom, attendance_number: 1, password: "password123")
    @assignment = Assignment.create!(teacher: @teacher, title: "Concurrent ink", point_per_question: 5)
    @assignment.assignment_classrooms.create!(classroom: @classroom)
    @assignment.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")), filename: "material.pdf", content_type: "application/pdf")
    @draft = AnswerDraft.create!(student: @student, assignment: @assignment,
      material_fingerprint: AnswerDraftContext.fingerprint(@assignment), page_data: [ { page_number: 1, operations: [] } ])
    @headers = { "X-Handwritten-Submission" => "1", "X-Draft-Context" => AnswerDraftContext.issue(@student, @assignment), "Accept" => "application/json" }
    @clients = 2.times.map do
      client = ActionDispatch::Integration::Session.new(Rails.application)
      client.post student_login_path, params: { student_session: { school_code: @school.school_code,
        grade: 1, class_number: 1, attendance_number: 1, password: "password123" } }
      client
    end
    clear_enqueued_jobs
  end

  after do
    @release << true
    @threads.each { |thread| raise "Live test thread" unless thread.join(15) }
    AssignmentDeletion.new.call(@assignment, teacher: @teacher) if Assignment.exists?(@assignment.id)
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
    @student.destroy!
    @classroom.destroy!
    @teacher.destroy!
    @school.destroy!
    clear_enqueued_jobs
  end

  def worker(hold: false, &block)
    pid = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        connection.execute("SET lock_timeout = '8s'")
        Thread.current[:hold_ink_submission] = hold
        pid << connection.select_value("SELECT pg_backend_pid()")
        begin
          block.call
        ensure
          connection.execute("SET lock_timeout = DEFAULT")
        end
      end
    end
    @threads << thread
    [ thread, Timeout.timeout(5) { pid.pop } ]
  end

  def post_ink(client, token: nil)
    params = {
      draft_version: "0", submission: { answer_file: fixture_file_upload(Rails.root.join("spec/fixtures/files/material.pdf"), "application/pdf") }
    }
    params[:submission_token] = token if token
    client.post student_assignment_submission_path(@assignment), params: params, headers: @headers
    client.response.status
  end

  def wait_blocked(pid)
    Timeout.timeout(5) do
      sleep 0.01 until ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)}))").positive?
    end
  end

  it "serializes two browser sessions and registers exactly one submission and reading job" do
    allow_any_instance_of(ActiveStorage::Blob).to receive(:upload_without_unfurling).and_wrap_original do |original, *args|
      original.call(*args)
      if Thread.current[:hold_ink_submission]
        @entered << true
        Timeout.timeout(10) { @release.pop }
      end
    end
    first, = worker(hold: true) { post_ink(@clients[0]) }
    Timeout.timeout(5) { @entered.pop }
    second, pid = worker { post_ink(@clients[1]) }
    wait_blocked(pid)
    @release << true
    expect(first.value).to eq(200)
    expect(second.value).to eq(200)
    expect(Submission.where(assignment: @assignment).count).to eq(1)
    expect(enqueued_jobs.count { |job| job[:job] == AnswerReadingJob }).to eq(1)
    expect(@draft.reload).to be_persisted
  end

  it "rejects a different tab's attempt token after the first submission commits" do
    allow_any_instance_of(ActiveStorage::Blob).to receive(:upload_without_unfurling).and_wrap_original do |original, *args|
      original.call(*args)
      if Thread.current[:hold_ink_submission]
        @entered << true
        Timeout.timeout(10) { @release.pop }
      end
    end
    first_token = SecureRandom.uuid
    first, = worker(hold: true) { post_ink(@clients[0], token: first_token) }
    Timeout.timeout(5) { @entered.pop }
    second, pid = worker { post_ink(@clients[1], token: SecureRandom.uuid) }
    wait_blocked(pid)
    @release << true
    expect(first.value).to eq(200)
    expect(second.value).to eq(409)
    expect(Submission.where(assignment: @assignment).count).to eq(1)
    expect(enqueued_jobs.count { |job| job[:job] == AnswerReadingJob }).to eq(1)
    expect(Submission.find_by!(assignment: @assignment).answer_file.blob.metadata["handwritten_submission_token"]).to eq(first_token)
  end

  it "makes autosave wait for a committed submission, then refuses to edit the retained draft" do
    allow_any_instance_of(Submission).to receive(:save!).and_wrap_original do |original, *args|
      result = original.call(*args)
      if Thread.current[:hold_ink_submission]
        @entered << true
        Timeout.timeout(10) { @release.pop }
      end
      result
    end
    first, = worker(hold: true) { post_ink(@clients[0]) }
    Timeout.timeout(5) { @entered.pop }
    second, pid = worker do
      @clients[1].patch student_assignment_answer_draft_path(@assignment), params: {
        expected_version: 0, draft_data: { format_version: 1, pages: @draft.page_data }
      }, headers: @headers, as: :json
      @clients[1].response.status
    end
    wait_blocked(pid)
    @release << true
    expect(first.value).to eq(200)
    expect(second.value).to eq(403)
    expect(@draft.reload.lock_version).to eq(0)
    expect(Submission.where(assignment: @assignment).count).to eq(1)
  end
  it "serializes appended ink from two tabs and retains exactly one operation" do
    allow_any_instance_of(AnswerDraft).to receive(:save!).and_wrap_original do |original, *args|
      result = original.call(*args)
      if Thread.current[:hold_ink_submission]
        @entered << true
        Timeout.timeout(10) { @release.pop }
      end
      result
    end
    append = lambda do |client|
      client.put student_assignment_answer_draft_path(@assignment), params: {
        expected_version: 0, append_data: { format_version: 1, pages: [ { page_number: 1,
          operations: [ { id: 1, tool: "pen", color: "#000000", width: 1.2, points: [ [ 20.123456789, 30 ] ] } ] } ] }
      }, headers: @headers, as: :json
      client.response.status
    end
    first, = worker(hold: true) { append.call(@clients[0]) }
    Timeout.timeout(5) { @entered.pop }
    second, pid = worker { append.call(@clients[1]) }
    wait_blocked(pid)
    @release << true
    expect(first.value).to eq(200)
    expect(second.value).to eq(409)
    expect(@draft.reload.lock_version).to eq(1)
    expect(@draft.page_data.first.fetch("operations").length).to eq(1)
    expect(Submission.where(assignment: @assignment)).to be_empty
    expect(enqueued_jobs.count { |job| job[:job] == AnswerReadingJob }).to eq(0)
  end
end
