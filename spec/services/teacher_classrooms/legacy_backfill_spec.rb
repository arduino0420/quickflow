require "rails_helper"
require_relative "../../support/ai_grading_context"

RSpec.describe TeacherClassrooms::LegacyBackfill do
  include_context "AI grading records"

  let(:colleague) { Teacher.create!(school: school, user_id: "colleague", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher_id: teacher.id, grade: 1, class_number: 1) }
  let(:other_classroom) { Classroom.create!(school: school, teacher_id: colleague.id, grade: 2, class_number: 1) }
  let(:foreign_school) { School.create!(school_code: "FOREIGN") }
  let(:foreign_teacher) { Teacher.create!(school: foreign_school, user_id: "foreign", password: "password123") }
  let(:service) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  before do
    classroom
    other_classroom
  end

  def legacy_pairs
    Classroom.order(:id).pluck(:teacher_id, :id)
  end

  def pairs
    TeacherClassroom.pluck(:teacher_id, :classroom_id)
  end

  def snapshot
    [ School, Teacher, Classroom, Student, Assignment, AssignmentClassroom, Submission, Question, GradingResult,
      ActiveStorage::Blob, ActiveStorage::Attachment, ActiveStorage::VariantRecord ].to_h do |model|
      [ model.name, model.order(:id).map(&:attributes) ]
    end
  end

  def diagnosed_backfill_call
    service.call
  rescue StandardError => error
    report_lock_failure(error) if Rails.env.test? && lock_acquisition_error?(error)
    raise
  end

  def lock_acquisition_error?(error)
    while error
      return true if error.is_a?(ActiveRecord::LockWaitTimeout) || error.is_a?(PG::LockNotAvailable)

      error = error.cause
    end
    false
  end

  def report_lock_failure(error)
    locks = connection.select_all(<<~SQL).to_a
      SELECT l.pid, l.locktype, l.relation::regclass::text AS relation, l.mode, l.granted,
             a.backend_type, a.state, (a.xact_start IS NOT NULL) AS in_transaction
      FROM pg_locks l
      LEFT JOIN pg_stat_activity a ON a.pid = l.pid
      WHERE l.locktype = 'relation'
        AND l.relation IN ('schools'::regclass, 'teachers'::regclass,
                           'classrooms'::regclass, 'teacher_classrooms'::regclass)
      ORDER BY l.relation, l.pid, l.mode
    SQL
    # NOWAIT does not leave this session waiting, so this may be empty. The
    # granted locks above provide a second snapshot of possible blockers.
    blocking_pids = connection.select_value("SELECT pg_blocking_pids(pg_backend_pid())")
    warn "LegacyBackfill lock diagnostics: #{ { error_class: error.class.name,
      current_pid: connection.select_value('SELECT pg_backend_pid()'), blocking_pids: blocking_pids,
      locks: locks }.to_json }"
  rescue StandardError => diagnostic_error
    warn "LegacyBackfill lock diagnostics unavailable: #{diagnostic_error.class.name}"
  end

  it "copies every legacy pair and reports matching totals" do
    expected = legacy_pairs
    report = diagnosed_backfill_call

    expect(pairs).to match_array(expected)
    expect(report).to eq(legacy_pairs: expected.size, inserted_pairs: expected.size,
      already_present_pairs: 0, total_pairs: expected.size)
  end

  it "is repeatable without changing existing intermediate attributes" do
    diagnosed_backfill_call
    original = TeacherClassroom.order(:id).map(&:attributes)

    expect(diagnosed_backfill_call[:inserted_pairs]).to eq(0)
    expect(TeacherClassroom.order(:id).map(&:attributes)).to eq(original)
  end

  it "preserves extra teachers for the same classroom and existing legacy links" do
    extra = TeacherClassroom.create!(teacher: colleague, classroom: classroom)
    existing = TeacherClassroom.create!(teacher: teacher, classroom: classroom)
    original = [ extra, existing ].map(&:attributes)
    expected = legacy_pairs + [ [ colleague.id, classroom.id ] ]

    expect(diagnosed_backfill_call[:inserted_pairs]).to eq(legacy_pairs.size - 1)
    expect(pairs).to match_array(expected)
    expect([ extra, existing ].map { |record| record.reload.attributes }).to eq(original)
  end

  it "audits all legacy pairs before inserting anything" do
    other_classroom.update_columns(teacher_id: foreign_teacher.id)
    original = snapshot

    expect { diagnosed_backfill_call }.to raise_error(described_class::InconsistentData, /旧担当: 1件/)
    expect(TeacherClassroom.count).to eq(0)
    expect(snapshot).to eq(original)
  end

  it "stops without repairing an existing cross-school intermediate link" do
    invalid = TeacherClassroom.new(teacher: foreign_teacher, classroom: classroom)
    invalid.save!(validate: false)
    original = invalid.attributes

    expect { diagnosed_backfill_call }.to raise_error(described_class::InconsistentData, /既存中間レコード: 1件/)
    expect(TeacherClassroom.all).to contain_exactly(invalid)
    expect(invalid.reload.attributes).to eq(original)
  end

  it "rolls back all inserted rows if an error occurs after insertion" do
    existing = TeacherClassroom.create!(teacher: colleague, classroom: classroom)
    original = existing.attributes
    allow(connection).to receive(:exec_query).and_wrap_original do |method, sql, *args, **kwargs|
      result = method.call(sql, *args, **kwargs)
      raise ActiveRecord::StatementInvalid, "Injected failure after insertion" if sql.include?("INSERT INTO teacher_classrooms")
      result
    end

    expect { diagnosed_backfill_call }.to raise_error(ActiveRecord::StatementInvalid)
    expect(TeacherClassroom.all).to contain_exactly(existing)
    expect(existing.reload.attributes).to eq(original)
  end

  it "checks actual pairs instead of trusting equal row counts and rolls back a mismatch" do
    allow(connection).to receive(:exec_query).and_wrap_original do |method, sql, *args, **kwargs|
      result = method.call(sql, *args, **kwargs)
      if sql.include?("INSERT INTO teacher_classrooms")
        # Simulate a faulty copy with the right count but the wrong teacher.
        connection.execute("UPDATE teacher_classrooms SET teacher_id = #{colleague.id} WHERE classroom_id = #{classroom.id}")
      end
      result
    end

    expect { diagnosed_backfill_call }.to raise_error(described_class::VerificationFailed)
    expect(TeacherClassroom.count).to eq(0)
  end

  it "keeps schools, teachers, classes, students, quizzes, PDFs and grading records unchanged" do
    submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nanswer"), filename: "answer.pdf", content_type: "application/pdf")
    submission.grading_results.create!(question: create_question, ai_judgment: :needs_review,
      teacher_judgment: :correct, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    original = snapshot
    files = [ assignment.material_file.blob, submission.answer_file.blob ].map { |blob| [ blob, blob.download ] }

    diagnosed_backfill_call

    expect(snapshot).to eq(original)
    files.each { |blob, content| expect(blob.download).to eq(content) }
    expect(teacher.reload.classrooms).to contain_exactly(classroom)
  end

  it "uses SQL without invoking the evolving application models" do
    [ Classroom, Teacher, TeacherClassroom ].each do |model|
      expect(model).not_to receive(:new)
      expect(model).not_to receive(:create!)
    end

    expect(diagnosed_backfill_call[:inserted_pairs]).to eq(legacy_pairs.size)
  end

  it "fails immediately without inserting while another connection holds a write lock" do
    other = PG.connect(connection.raw_connection.conninfo_hash.reject { |_key, value| value.blank? })
    begin
      other.exec("BEGIN")
      other.exec("LOCK TABLE teacher_classrooms IN ROW EXCLUSIVE MODE")
      expect { diagnosed_backfill_call }.to raise_error(ActiveRecord::LockWaitTimeout)
      expect(TeacherClassroom.count).to eq(0)
    ensure
      other.exec("ROLLBACK")
      other.close
    end
  end
end
