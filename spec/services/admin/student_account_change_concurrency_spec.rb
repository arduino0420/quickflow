require "rails_helper"
require "timeout"

RSpec.describe "Admin student account concurrency" do
  self.use_transactional_tests = false

  before do
    @school = School.create!(school_code: "RACE#{SecureRandom.hex(4)}")
    @admin = Admin.create!(school: @school, user_id: "race-admin-#{SecureRandom.hex(4)}", password: "admin-secret")
    @teacher = Teacher.create!(school: @school, user_id: "race-teacher-#{SecureRandom.hex(4)}", password: "teacher-secret")
    @room = Classroom.create!(school: @school, grade: 1, class_number: 1)
    @student = Student.create!(classroom: @room, attendance_number: 1, password: "original-secret")
    @assignment = Assignment.create!(teacher: @teacher, title: "Race safety", point_per_question: 5)
    @threads = []
  end

  after do
    worker_errors = []
    @threads.each do |thread|
      begin
        thread.join(10)
      rescue StandardError => error
        worker_errors << error
      end
    end
    raise "Live worker prevents safe cleanup" if @threads.any?(&:alive?)

    AnswerDraft.where(student_id: @student.id).delete_all
    Submission.where(student_id: @student.id).delete_all
    AssignmentClassroom.where(assignment: @assignment).delete_all
    @assignment.destroy!
    Student.where(classroom: @school.classrooms).delete_all
    @school.classrooms.destroy_all
    @teacher.destroy!
    @admin.destroy!
    @school.destroy!
    raise worker_errors.first if worker_errors.any?
  end

  def account
    Admin::StudentAccountChange.new(admin: @admin, student_id: @student.id)
  end

  # Keep an actual SQL write uncommitted in another connection. No sleeps or
  # shared transaction tricks: the management operation meets PostgreSQL locks.
  def while_write_uncommitted(&write)
    ready = Queue.new
    release = Queue.new
    @threads << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActiveRecord::Base.transaction do
          write.call
          ready << true
          Timeout.timeout(8) { release.pop }
        end
      end
    end
    Timeout.timeout(8) { ready.pop }
    begin
      yield_result = yield_management
    ensure
      release << true
      raise "Writer timed out" unless @threads.last.join(10)
      @threads.last.value
    end
    yield_result
  end

  def yield_management
    @management.call
  end

  it "rejects deletion while a draft insert holds the student's foreign-key lock" do
    editor = account
    token = editor.prepare("delete").token
    @management = -> { editor.call(operation: "delete", token: token) }
    result = while_write_uncommitted do
      AnswerDraft.create!(student: @student, assignment: @assignment, material_fingerprint: "a" * 64,
        page_data: [ { "page_number" => 1, "operations" => [] } ])
    end
    expect(result).to be(false)
    expect(AnswerDraft.where(student: @student).count).to eq(1)
    expect(@student.reload).to be_persisted
  end

  it "rejects deletion while a formal submission and its distribution are committing" do
    editor = account
    token = editor.prepare("delete").token
    @management = -> { editor.call(operation: "delete", token: token) }
    result = while_write_uncommitted do
      @assignment.assignment_classrooms.create!(classroom: @room)
      Submission.create!(student: @student, assignment: @assignment, submitted_at: Time.current)
    end
    expect(result).to be(false)
    expect(Submission.where(student: @student).count).to eq(1)
    expect(@student.reload).to be_persisted
  end

  it "rejects a membership correction while a new distribution is committing" do
    destination = @school.classrooms.create!(grade: 2, class_number: 1)
    editor = account
    initial = editor.prepare("edit").token
    expect(editor.preview(attributes: { grade: "2", class_number: "1", attendance_number: "1" }, token: initial)).to be(true)
    confirmation = editor.token
    @management = -> { editor.call(operation: "update", token: confirmation) }
    result = while_write_uncommitted { @assignment.assignment_classrooms.create!(classroom: destination) }
    expect(result).to be(false)
    expect(@student.reload.classroom_id).to eq(@room.id)
    expect(@assignment.assignment_classrooms.count).to eq(1)
  end

  it "rejects a membership correction while a draft is committing" do
    editor = account
    initial = editor.prepare("edit").token
    expect(editor.preview(attributes: { grade: "2", class_number: "1", attendance_number: "1" }, token: initial)).to be(true)
    confirmation = editor.token
    @management = -> { editor.call(operation: "update", token: confirmation) }
    result = while_write_uncommitted do
      AnswerDraft.create!(student: @student, assignment: @assignment, material_fingerprint: "a" * 64,
        page_data: [ { "page_number" => 1, "operations" => [] } ])
    end
    expect(result).to be(false)
    expect(@student.reload.classroom_id).to eq(@room.id)
    expect(AnswerDraft.where(student: @student).count).to eq(1)
  end

  it "accepts exactly one of two simultaneous password changes from the same form" do
    token = account.prepare("password").token
    ready = Queue.new
    release = Queue.new
    [ "58392047", "72618490" ].each do |password|
      @threads << Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          editor = account
          ready << true
          Timeout.timeout(8) { release.pop }
          [ editor.call(operation: "password", token: token, attributes: { password: password, password_confirmation: password }), password ]
        end
      end
    end
    Timeout.timeout(8) { 2.times { ready.pop } }
    2.times { release << true }
    results = @threads.map { |thread| raise "Worker timed out" unless thread.join(10); thread.value }
    expect(results.map(&:first)).to contain_exactly(true, false)
    winner = results.find(&:first).last
    expect(@student.reload.authenticate(winner)).to eq(@student)
  end

  it "preserves referential integrity when deletion commits before a new draft insert" do
    editor = account
    token = editor.prepare("delete").token
    deleted = Queue.new
    release = Queue.new
    allow(editor.student).to receive(:destroy!).and_wrap_original do |original|
      original.call
      deleted << true
      Timeout.timeout(8) { release.pop }
    end
    @threads << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        editor.call(operation: "delete", token: token)
      end
    end
    Timeout.timeout(8) { deleted.pop }
    writer_ready = Queue.new
    @threads << Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        writer_ready << true
        begin
          # Exercise the database FK directly; Rails can reject earlier during
          # belongs_to validation if the deletion has already committed.
          AnswerDraft.insert_all!([ { student_id: @student.id, assignment_id: @assignment.id, material_fingerprint: "a" * 64,
            page_data: [ { "page_number" => 1, "operations" => [] } ] } ])
        rescue ActiveRecord::InvalidForeignKey => error
          error.class
        end
      end
    end
    begin
      Timeout.timeout(8) { writer_ready.pop }
    ensure
      release << true
    end
    @threads.each { |thread| raise "Worker timed out" unless thread.join(10) }
    expect(@threads.first.value).to be(true)
    expect(@threads.last.value).to eq(ActiveRecord::InvalidForeignKey)
    expect(Student.exists?(@student.id)).to be(false)
    expect(AnswerDraft.where(student_id: @student.id)).to be_empty
    expect(@assignment.reload).to be_persisted
  end
end
