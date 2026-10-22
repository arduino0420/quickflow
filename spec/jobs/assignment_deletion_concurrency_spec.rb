require "rails_helper"
require "timeout"
require_relative "../support/ai_grading_context"

RSpec.describe "Assignment deletion concurrency", type: :job do
  include_context "AI grading records"
  include ActiveJob::TestHelper
  include Rails.application.routes.url_helpers
  self.use_transactional_tests = false

  before do
    @threads = []
    @additional_students = []
    @additional_assignment_ids = []
    assignment.assignment_classrooms.create!(classroom: classroom)
    submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nanswer"), filename: "answer.pdf", content_type: "application/pdf")
    @submission_id = submission.id
    @assignment_id = assignment.id
  end

  after do
    thread_errors = []
    @threads.each do |thread|
      begin
        raise "Worker did not finish before cleanup" unless thread.join(10)
      rescue StandardError => error
        thread_errors << error
      end
    end
    raise "Live worker prevents safe cleanup" if @threads.any?(&:alive?)

    begin
      [ @assignment_id, *@additional_assignment_ids ].each do |id|
        item = Assignment.find_by(id: id)
        AssignmentDeletion.new.call(item, teacher: teacher) if item
      end
      perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
      @additional_students.each(&:destroy!)
      student.destroy!
      TeacherClassroom.where(classroom_id: classroom.id).delete_all
      classroom.destroy!
      teacher.destroy!
      school.destroy!
      expect(Assignment.exists?(@assignment_id)).to be(false)
    ensure
      clear_enqueued_jobs
    end
    raise thread_errors.first if thread_errors.any?
  end

  def run_thread(&block)
    thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        Thread.current[:database_pid] = connection.select_value("SELECT pg_backend_pid()")
        connection.execute("SET lock_timeout = '8s'")
        begin
          block.call(connection)
        ensure
          connection.execute("SET lock_timeout = DEFAULT")
        end
      end
    end
    @threads << thread
    thread
  end

  def wait_until_blocked(pid, by:)
    Timeout.timeout(5) do
      loop do
        blockers = ActiveRecord::Base.connection.select_values("SELECT unnest(pg_blocking_pids(#{Integer(pid)}))")
        break if blockers.map(&:to_i).include?(Integer(by))

        sleep 0.01
      end
    end
  end

  def assert_deleted
    expect(Assignment.exists?(@assignment_id)).to be(false)
    expect(Submission.exists?(@submission_id)).to be(false)
    expect(Question.where(assignment_id: @assignment_id)).to be_empty
    expect(GradingResult.joins(:submission).where(submissions: { assignment_id: @assignment_id })).to be_empty
  end

  def deletion_behind_job(job_class, *args)
    entered = Queue.new
    release = Queue.new
    pid = Queue.new
    yield(entered, release)
    worker = run_thread { job_class.perform_now(*args) }
    Timeout.timeout(5) { entered.pop }
    deletion = run_thread do |connection|
      pid << connection.select_value("SELECT pg_backend_pid()")
      AssignmentDeletion.new.call(Assignment.find(@assignment_id), teacher: teacher)
    end
    wait_until_blocked(Timeout.timeout(5) { pid.pop }, by: worker[:database_pid])
    release << true
    expect(worker.join(10)).to be_present
    expect(deletion.join(10)).to be_present
    worker.value
    expect(deletion.value).to eq(:deleted)
    assert_deleted
  ensure
    release << true if release
    [ worker, deletion ].compact.each { |thread| thread.join(10) }
  end

  it "waits for running question generation before deleting its generated questions" do
    allow(AiClient).to receive(:build).and_return(client)
    allow(files).to receive(:create).and_return(double(id: "stub-material"))
    blob_id = assignment.material_file.blob.id
    deletion_behind_job(QuestionGenerationJob, Assignment.find(@assignment_id), blob_id) do |entered, release|
      expect(responses).to receive(:create).once do
        entered << true
        Timeout.timeout(8) { release.pop }
        ai_response(questions: [ { question_label: "1(1)", question_text: "3x+2x", correct_answer: "5x",
          grading_rule: "同類項", requires_work: false } ])
      end
    end
  end

  it "waits for reading and safely handles a grading enqueue racing with deletion" do
    submission.update!(extracted_text: nil)
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    deletion_behind_job(AnswerReadingJob, Submission.find(@submission_id)) do |entered, release|
      expect(reader).to receive(:call).once do
        entered << true
        Timeout.timeout(8) { release.pop }
        JSON.generate(problems: [ problem ])
      end
    end
  end

  it "waits for grading before deleting results without deadlock or recreated records" do
    question = create_question
    allow(AiClient).to receive(:build).and_return(client)
    deletion_behind_job(AnswerGradingJob, Submission.find(@submission_id)) do |entered, release|
      expect(responses).to receive(:create).once do
        entered << true
        Timeout.timeout(8) { release.pop }
        ai_response(results: [ judgment(question) ])
      end
    end
  end

  it "waits until after-commit answer upload finishes before deleting and purging the answer" do
    # A second pupil follows the controller's save/lock path and pauses in the storage upload.
    other = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    @additional_students << other
    entered = Queue.new
    release = Queue.new
    pid = Queue.new
    allow_any_instance_of(ActiveStorage::Service::DiskService).to receive(:upload).and_wrap_original do |method, *args, **options|
      entered << true
      Timeout.timeout(8) { release.pop }
      method.call(*args, **options)
    end
    uploader = run_thread do
      AssignmentLifecycleLock.synchronize(@assignment_id) do
        item = Assignment.find(@assignment_id)
        item.with_lock("FOR KEY SHARE") do
          Submission.create!(assignment: item, student: other, submitted_at: Time.current,
            answer_file: { io: StringIO.new("%PDF-1.4\nupload"), filename: "upload.pdf", content_type: "application/pdf" })
        end
      end
    end
    Timeout.timeout(5) { entered.pop }
    deletion = run_thread do |connection|
      pid << connection.select_value("SELECT pg_backend_pid()")
      AssignmentDeletion.new.call(Assignment.find(@assignment_id), teacher: teacher)
    end
    wait_until_blocked(Timeout.timeout(5) { pid.pop }, by: uploader[:database_pid])
    expect(deletion).to be_alive
    release << true
    expect(uploader.join(10)).to be_present
    expect(deletion.join(10)).to be_present
    uploaded = uploader.value
    expect(deletion.value).to eq(:deleted)
    expect(Submission.exists?(uploaded.id)).to be(false)
    assert_deleted
  ensure
    release << true if release
    [ uploader, deletion ].compact.each { |thread| thread.join(10) }
  end

  it "refuses a submission holding an old assignment object when deletion wins first" do
    stale = Assignment.find(@assignment_id)
    AssignmentDeletion.new.call(assignment, teacher: teacher)
    expect {
      AssignmentLifecycleLock.synchronize(stale.id) do
        stale.with_lock("FOR KEY SHARE") do
          Submission.create!(assignment: stale, student: student, submitted_at: Time.current)
        end
      end
    }.to raise_error(ActiveRecord::RecordNotFound)
    assert_deleted
  end

  it "serializes deletion with three simultaneous jobs and proves each blocking dependency" do
    question = create_question
    other = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    @additional_students << other
    reading_submission = Submission.create!(assignment: assignment, student: other, submitted_at: Time.current)
    entered = { generation: Queue.new, grading: Queue.new, reading: Queue.new }
    releases = { generation: Queue.new, grading: Queue.new, reading: Queue.new }
    allow_any_instance_of(QuestionGenerator).to receive(:call).and_wrap_original do |method, item, **options|
      item.with_lock("FOR NO KEY UPDATE") do
        entered[:generation] << true
        Timeout.timeout(8) { releases[:generation].pop }
        method.call(item, **options)
      end
    end
    grader = instance_double(AnswerGrader)
    allow(AnswerGrader).to receive(:new).and_return(grader)
    expect(grader).to receive(:call).once do
      entered[:grading] << true
      Timeout.timeout(8) { releases[:grading].pop }
      [ judgment(question).merge(ai_model_name: "test", prompt_version: "v1", graded_at: Time.current) ]
    end
    reader = instance_double(AnswerReader)
    allow(AnswerReader).to receive(:new).and_return(reader)
    expect(reader).to receive(:call).once do
      entered[:reading] << true
      Timeout.timeout(8) { releases[:reading].pop }
      JSON.generate(problems: [ problem ])
    end
    generation = run_thread { QuestionGenerationJob.perform_now(Assignment.find(@assignment_id), assignment.material_file.blob.id) }
    grading = run_thread { AnswerGradingJob.perform_now(Submission.find(@submission_id)) }
    reading = run_thread { AnswerReadingJob.perform_now(Submission.find(reading_submission.id)) }
    entered.each_value { |queue| Timeout.timeout(5) { queue.pop } }
    pid = Queue.new
    deletion = run_thread do |connection|
      pid << connection.select_value("SELECT pg_backend_pid()")
      AssignmentDeletion.new.call(Assignment.find(@assignment_id), teacher: teacher)
    end
    deletion_pid = Timeout.timeout(5) { pid.pop }
    wait_until_blocked(deletion_pid, by: generation[:database_pid])
    releases[:generation] << true
    expect(generation.join(10)).to be_present
    generation.value
    wait_until_blocked(deletion_pid, by: grading[:database_pid])
    releases[:grading] << true
    expect(grading.join(10)).to be_present
    grading.value
    wait_until_blocked(deletion_pid, by: reading[:database_pid])
    releases[:reading] << true
    expect(reading.join(10)).to be_present
    reading.value
    expect(deletion.join(10)).to be_present
    expect(deletion.value).to eq(:deleted)
    expect(Submission.exists?(reading_submission.id)).to be(false)
    assert_deleted
  ensure
    releases&.each_value { |queue| queue << true }
    [ generation, grading, reading, deletion ].compact.each { |thread| thread.join(10) }
  end

  it "keeps a teacher assignment invisible until its material upload succeeds, then permits deletion" do
    request_session = ActionDispatch::Integration::Session.new(Rails.application)
    request_session.post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
    entered = Queue.new
    release = Queue.new
    title = "material-race-#{SecureRandom.hex(4)}"
    allow_any_instance_of(ActiveStorage::Service::DiskService).to receive(:upload).and_wrap_original do |method, *args, **options|
      entered << true
      Timeout.timeout(8) { release.pop }
      method.call(*args, **options)
    end
    creator = run_thread do
      request_session.post assignments_path, params: { assignment: { title: title, point_per_question: 5,
        classroom_ids: [ classroom.id.to_s ], material_file: Rack::Test::UploadedFile.new(Rails.root.join("spec/fixtures/files/material.pdf"), "application/pdf") } }
      request_session.response.status
    end
    Timeout.timeout(5) { entered.pop }
    expect(teacher.assignments.exists?(title: title)).to be(false)
    release << true
    expect(creator.join(10)).to be_present
    expect(creator.value).to eq(303)
    created = teacher.assignments.find_by!(title: title)
    @additional_assignment_ids << created.id
    blob = created.material_file.blob
    expect(blob.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
    deletion = run_thread do
      AssignmentDeletion.new.call(Assignment.find(created.id), teacher: teacher)
    end
    expect(deletion.join(10)).to be_present
    expect(deletion.value).to eq(:deleted)
    perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
    expect(Assignment.exists?(created.id)).to be(false)
    expect(blob.service.exist?(blob.key)).to be(false)
  ensure
    release << true if release
    [ creator, deletion ].compact.each { |thread| thread.join(10) }
    if title && (created_id = teacher.assignments.find_by(title: title)&.id)
      @additional_assignment_ids << created_id
    end
  end
end
