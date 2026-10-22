require "rails_helper"
require "timeout"
require_relative "../support/ai_grading_context"

RSpec.describe "Student PDF upload safety", type: :request do
  include ActiveJob::TestHelper
  include_context "AI grading records"
  self.use_transactional_tests = false

  before do
    raise "quickflow_test required" unless Rails.env.test? && ActiveRecord::Base.connection_db_config.database == "quickflow_test"

    @threads = []
    @release = Queue.new
    @entered = Queue.new
    @uploads = []
    assignment.assignment_classrooms.create!(classroom: classroom)
    student
    @clients = 2.times.map do
      client = ActionDispatch::Integration::Session.new(Rails.application)
      client.post student_login_path, params: { student_session: { school_code: school.school_code,
        grade: classroom.grade, class_number: classroom.class_number,
        attendance_number: student.attendance_number, password: "password123" } }
      raise "test login failed" unless client.response.status == 303

      client
    end
    allow(ActiveStorage::Blob).to receive(:build_after_unfurling).and_wrap_original do |method, *args, **options|
      method.call(*args, **options).tap { |blob| @uploads << blob }
    end
    clear_enqueued_jobs
  end

  after do
    @release << true
    @threads.each { |thread| raise "Live upload worker" unless thread.join(15) }
    AssignmentDeletion.new.call(assignment, teacher: teacher) if Assignment.exists?(assignment.id)
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
    @uploads.each do |uploaded|
      blob = ActiveStorage::Blob.find_by(id: uploaded.id)
      blob.purge if blob && !blob.attachments.exists?
    end
    student.destroy!
    TeacherClassroom.where(classroom_id: classroom.id).delete_all
    classroom.destroy!
    teacher.destroy!
    school.destroy!
  ensure
    clear_enqueued_jobs
  end

  def post_pdf(client = @clients.first)
    client.post student_assignment_submission_path(assignment), params: {
      submission: { answer_file: fixture_file_upload(Rails.root.join("spec/fixtures/files/material.pdf"), "application/pdf") }
    }
    client.response.status
  end

  def record_counts
    [ Submission.count, ActiveStorage::Attachment.count, ActiveStorage::Blob.count ]
  end

  def reading_job_count
    enqueued_jobs.count { |job| job[:job] == AnswerReadingJob }
  end

  [ :before_write, :after_write ].each do |stage|
    it "keeps a #{stage} storage failure unsubmitted and allows a successful retry" do
      original_counts = record_counts
      fail_once = true
      allow_any_instance_of(ActiveStorage::Blob).to receive(:upload_without_unfurling).and_wrap_original do |method, *args|
        if fail_once
          fail_once = false
          method.call(*args) if stage == :after_write
          raise IOError, "private storage details"
        end
        method.call(*args)
      end
      begin
        post_pdf
      rescue IOError
        # Let the regression assertion expose the old committed Submission.
      end

      count = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { Submission.where(assignment: assignment, student: student).count }
      end.value
      expect(count).to eq(0)
      expect(record_counts).to eq(original_counts)
      expect(reading_job_count).to eq(0)
      expect(@clients.first.response.status).to eq(503)
      expect(@clients.first.response.body).to include("答案PDFを保存できませんでした")
      expect(@clients.first.response.body).not_to include("private storage details", "提出しました")
      failed_blob = @uploads.sole
      expect(failed_blob.service.exist?(failed_blob.key)).to be(false)
      expect(assignment.material_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))

      @clients.first.get student_assignment_path(assignment)
      expect(Nokogiri::HTML(@clients.first.response.body).at_css("input[type='file']")).to be_present
      expect(post_pdf).to eq(303)
      saved = Submission.find_by!(assignment: assignment, student: student)
      expect(saved.answer_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
      expect(reading_job_count).to eq(1)
    end
  end

  it "cleans only its new upload if Submission validation fails" do
    unrelated = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("unrelated"), filename: "keep.txt")
    original_counts = record_counts
    allow_any_instance_of(Submission).to receive(:save!).and_wrap_original do |method|
      method.receiver.errors.add(:base, "保存できませんでした")
      raise ActiveRecord::RecordInvalid.new(method.receiver)
    end

    expect(post_pdf).to eq(422)
    expect(record_counts).to eq(original_counts)
    expect(reading_job_count).to eq(0)
    expect(unrelated.reload.download).to eq("unrelated")
    failed_blob = @uploads.last
    expect(ActiveStorage::Blob.exists?(failed_blob.id)).to be(false)
    expect(failed_blob.service.exist?(failed_blob.key)).to be(false)
    expect(assignment.material_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
  end

  it "keeps the retryable response even if unused-blob cleanup also fails" do
    fail_cleanup = true
    allow_any_instance_of(ActiveStorage::Blob).to receive(:upload_without_unfurling).and_raise(IOError, "storage failed")
    allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_wrap_original do |method|
      raise IOError, "cleanup failed" if fail_cleanup

      method.call
    end

    expect(post_pdf).to eq(503)
    expect(Submission.where(assignment: assignment, student: student)).to be_empty
    expect(reading_job_count).to eq(0)
    expect(@uploads.sole.attachments).to be_empty
    expect(@clients.first.response.body).to include("答案PDFを保存できませんでした")
  ensure
    fail_cleanup = false
  end

  def worker(hold: false, &block)
    pid = Queue.new
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Thread.current[:hold_pdf_upload] = hold
        connection.execute("SET lock_timeout = '8s'")
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

  [ false, true ].each do |first_fails|
    it "serializes overlapping uploads when the first #{first_fails ? 'fails' : 'succeeds'}" do
      allow_any_instance_of(ActiveStorage::Blob).to receive(:upload_without_unfurling).and_wrap_original do |method, *args|
        method.call(*args)
        if Thread.current[:hold_pdf_upload]
          @entered << true
          Timeout.timeout(10) { @release.pop }
          raise IOError, "upload interrupted" if first_fails
        end
      end

      first, = worker(hold: true) { post_pdf(@clients[0]) }
      Timeout.timeout(5) { @entered.pop }
      second, pid = worker { post_pdf(@clients[1]) }
      Timeout.timeout(5) do
        sleep 0.01 until ActiveRecord::Base.connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(pid)}))").positive?
      end
      @release << true
      expect(first.value).to eq(first_fails ? 503 : 303)
      expect(second.value).to eq(303)
      expect(Submission.where(assignment: assignment, student: student).count).to eq(1)
      expect(reading_job_count).to eq(1)
      saved = Submission.find_by!(assignment: assignment, student: student)
      expect(saved.answer_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
      expect(@uploads.count { |blob| ActiveStorage::Blob.exists?(blob.id) }).to eq(1)
    ensure
      @release << true
    end
  end
end
