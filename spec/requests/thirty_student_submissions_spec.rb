require "rails_helper"
require "timeout"

RSpec.describe "Thirty concurrent student submissions", type: :request do
  include ActiveJob::TestHelper
  include Rails.application.routes.url_helpers
  self.use_transactional_tests = false

  STUDENT_COUNT = 30
  PDF_PATH = Rails.root.join("spec/fixtures/files/material.pdf")

  before do
    raise "quickflow_test required" unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database == "quickflow_test"

    @threads = []
    @start = Queue.new
    @ready = Queue.new
    @locked = Queue.new
    @unlock = Queue.new
    @request_slots = SizedQueue.new(3)
    3.times { @request_slots << true }
    @school = School.create!(school_code: "LOAD#{SecureRandom.hex(4)}")
    @teacher = Teacher.create!(school: @school, user_id: "load#{SecureRandom.hex(4)}", password: "test-password")
    @classroom = Classroom.create!(school: @school, grade: 1, class_number: 1)
    @assignment = Assignment.create!(teacher: @teacher, title: "Test-only concurrent quiz", point_per_question: 5)
    @assignment.assignment_classrooms.create!(classroom: @classroom)
    @assignment.material_file.attach(io: File.open(PDF_PATH), filename: "material.pdf", content_type: "application/pdf")
    @students = (1..STUDENT_COUNT).map do |number|
      Student.create!(classroom: @classroom, attendance_number: number, password: "test-password")
    end
    @clients = @students.map do |student|
      client = ActionDispatch::Integration::Session.new(Rails.application)
      client.post student_login_path, params: { student_session: { school_code: @school.school_code,
        grade: 1, class_number: 1, attendance_number: student.attendance_number, password: "test-password" } }
      raise "test login failed" unless client.response.status == 303

      client
    end
    clear_enqueued_jobs
  end

  after do
    STUDENT_COUNT.times { @start << true }
    @unlock << true
    join_errors = @threads.filter_map do |thread|
      begin
        raise "Live submission worker" unless thread.join(30)
      rescue StandardError => error
        error
      end
    end
    if @threads.any?(&:alive?)
      raise "Live worker prevents safe cleanup" unless RSpec.current_example.exception

      warn "Live worker prevents safe cleanup after test failure"
    else
      begin
        AssignmentDeletion.new.call(@assignment, teacher: @teacher) if @assignment && Assignment.exists?(@assignment.id)
        perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
        @students&.each(&:destroy!)
        @classroom&.destroy!
        @teacher&.destroy!
        @school&.destroy!
      rescue StandardError => error
        raise unless RSpec.current_example.exception

        warn "Test fixture cleanup failed: #{error.class}"
      ensure
        clear_enqueued_jobs
      end
      raise join_errors.first if join_errors.any? && !RSpec.current_example.exception
    end
  end

  def submit_together(handwritten:)
    drafts = if handwritten
      @students.map do |student|
        AnswerDraft.create!(student: student, assignment: @assignment,
          material_fingerprint: AnswerDraftContext.fingerprint(@assignment),
          page_data: [ { page_number: 1, operations: [] } ])
      end
    end
    held = false
    guard = Mutex.new
    assignment_id = @assignment.id
    allow(AssignmentLifecycleLock).to receive(:synchronize).and_wrap_original do |original, id, &block|
      original.call(id) do
        hold = guard.synchronize do
          next false if held || id != assignment_id

          held = true
        end
        if hold
          @locked << ActiveRecord::Base.connection.select_value("SELECT pg_backend_pid()")
          Timeout.timeout(20) { @unlock.pop }
        end
        block.call
      end
    end

    observer = ActiveRecord::Base.connection_pool.checkout
    @clients.each_with_index do |client, index|
      @threads << Thread.new do
        @ready << true
        Timeout.timeout(30) { @start.pop }
        Timeout.timeout(30) { @request_slots.pop }
        begin
          upload = Rack::Test::UploadedFile.new(PDF_PATH, "application/pdf")
          params = { submission: { answer_file: upload } }
          headers = {}
          if handwritten
            student = @students.fetch(index)
            params[:draft_version] = drafts.fetch(index).lock_version.to_s
            headers = { "X-Handwritten-Submission" => "1", "X-Draft-Context" => AnswerDraftContext.issue(student, @assignment),
              "Accept" => "application/json" }
          end
          client.post student_assignment_submission_path(@assignment), params: params, headers: headers
          client.response.status
        ensure
          @request_slots << true
        end
      end
    end
    STUDENT_COUNT.times { Timeout.timeout(10) { @ready.pop } }
    STUDENT_COUNT.times { @start << true }
    holder_pid = Timeout.timeout(15) { @locked.pop }
    expect(waiting_advisory_locks(observer, holder_pid)).to be > 0
    @unlock << true

    statuses = @threads.map { |thread| Timeout.timeout(30) { thread.value } }
    expect(statuses).to eq(Array.new(STUDENT_COUNT, handwritten ? 200 : 303))
    expect_saved_submissions
  ensure
    ActiveRecord::Base.connection_pool.checkin(observer) if observer
  end

  def waiting_advisory_locks(connection, holder_pid)
    Timeout.timeout(10) do
      loop do
        count = connection.select_value(<<~SQL).to_i
          SELECT count(*) FROM pg_locks AS waiting
          JOIN pg_locks AS held ON held.locktype = 'advisory' AND held.granted
            AND held.pid = #{Integer(holder_pid)}
            AND held.database = waiting.database AND held.classid = waiting.classid
            AND held.objid = waiting.objid AND held.objsubid = waiting.objsubid
          WHERE waiting.locktype = 'advisory' AND NOT waiting.granted
        SQL
        break count if count.positive?

        sleep 0.01
      end
    end
  end

  def expect_saved_submissions
    submissions = Submission.where(assignment: @assignment).order(:student_id).to_a
    expect(submissions.size).to eq(STUDENT_COUNT)
    expect(submissions.map(&:student_id).uniq.size).to eq(STUDENT_COUNT)
    expect(submissions.map(&:processing_generation).uniq).to eq([ 0 ])
    expected_pdf = File.binread(PDF_PATH)
    submissions.each do |item|
      expect(item.answer_file).to be_attached
      expect(item.answer_file.download).to eq(expected_pdf)
      expect(item.grading_results).to be_empty
    end
    reading_jobs = enqueued_jobs.select { |job| job[:job] == AnswerReadingJob }
    expect(reading_jobs.size).to eq(STUDENT_COUNT)
    job_global_ids = reading_jobs.map { |job| job.fetch(:args).first.fetch("_aj_globalid") }
    expect(job_global_ids.sort).to eq(submissions.map { |item| item.to_global_id.to_s }.sort)
    expect(enqueued_jobs.count { |job| job[:job] == AnswerGradingJob }).to eq(0)
  end

  it "saves thirty ordinary PDF uploads while requests contend for the same assignment lock" do
    submit_together(handwritten: false)
  end

  it "saves thirty handwritten PDF uploads with valid draft context and version" do
    submit_together(handwritten: true)
  end
end
