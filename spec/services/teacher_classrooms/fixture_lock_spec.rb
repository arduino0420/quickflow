require "rails_helper"
require "timeout"
require_relative "../../support/legacy_backfill_fixture"

RSpec.describe "LegacyBackfill fixture preparation" do
  include LegacyBackfillFixture

  let(:connection) { ActiveRecord::Base.connection }

  def other_connection
    PG.connect(connection.raw_connection.conninfo_hash.reject { |_key, value| value.blank? })
  end

  def with_other_transaction
    other = other_connection
    other.exec("BEGIN")
    other.exec("SET LOCAL lock_timeout = '2s'")
    yield other
  ensure
    other&.exec("ROLLBACK")
    other&.close
  end

  def preparation_locks
    connection.select_values(<<~SQL)
      SELECT relation::regclass::text
      FROM pg_locks
      WHERE pid = pg_backend_pid() AND granted AND mode = 'ShareUpdateExclusiveLock'
        AND relation IN ('schools'::regclass, 'teachers'::regclass,
                         'classrooms'::regclass, 'teacher_classrooms'::regclass)
    SQL
  end

  %w[ schools teachers classrooms teacher_classrooms ].each do |table|
    it "waits for an observed maintenance lock on #{table}, then prepares the fixture" do
      main_pid = connection.select_value("SELECT pg_backend_pid()")
      connection.execute("SET LOCAL lock_timeout = '137ms'")
      original_timeout = connection.select_value("SHOW lock_timeout")
      config = connection.raw_connection.conninfo_hash.reject { |_key, value| value.blank? }
      ready = Queue.new
      worker = Thread.new do
        other = PG.connect(config)
        other.exec("BEGIN")
        other.exec("SET LOCAL lock_timeout = '2s'")
        other.exec("LOCK TABLE #{table} IN SHARE UPDATE EXCLUSIVE MODE")
        ready << true
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        loop do
          blocked = other.exec_params("SELECT $1::int = ANY(pg_blocking_pids($2::int))",
            [ other.backend_pid, main_pid ]).getvalue(0, 0)
          break if blocked == "t"
          raise "Fixture never waited on the maintenance barrier" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          sleep 0.005
        end
        other.exec("ROLLBACK")
        true
      rescue StandardError => error
        ready << error
        raise
      ensure
        other&.close
      end

      signal = Timeout.timeout(5) { ready.pop }
      raise signal if signal.is_a?(Exception)
      prepare_legacy_backfill_fixture

      expect(worker.value).to be(true)
      expect(connection.select_value("SELECT pg_backend_pid()")).to eq(main_pid)
      expect(connection.select_value("SHOW lock_timeout")).to eq(original_timeout)
      expect(preparation_locks).to match_array(%w[ schools teachers classrooms teacher_classrooms ])
      expect(TeacherClassrooms::LegacyBackfill.new.call[:inserted_pairs]).to eq(0)
    ensure
      worker&.join
    end
  end

  it "retains all preparation locks after its savepoint and releases them on fixture rollback" do
    connection.transaction(requires_new: true) do
      prepare_legacy_backfill_fixture
      expect(preparation_locks).to match_array(%w[ schools teachers classrooms teacher_classrooms ])
      raise ActiveRecord::Rollback
    end

    expect(preparation_locks).to be_empty
    expect(connection.transaction_open?).to be(true)
    expect(connection.select_value("SELECT 1")).to eq(1)
    with_other_transaction do |other|
      expect(other.exec("LOCK TABLE schools, teachers, classrooms, teacher_classrooms IN SHARE UPDATE EXCLUSIVE MODE").cmd_status).to eq("LOCK TABLE")
    end
  end

  it "keeps later maintenance queued while the real service upgrades its prepared locks" do
    other = other_connection
    other.exec("BEGIN")
    other.exec("SET LOCAL lock_timeout = '5s'")
    main_pid = connection.select_value("SELECT pg_backend_pid()")

    connection.transaction(requires_new: true) do
      prepare_legacy_backfill_fixture
      other.send_query("LOCK TABLE schools IN SHARE UPDATE EXCLUSIVE MODE")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      loop do
        blocked = connection.select_value("SELECT #{main_pid} = ANY(pg_blocking_pids(#{other.backend_pid}))")
        break if blocked
        raise "Maintenance never waited on the prepared fixture" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.005
      end

      expect(TeacherClassrooms::LegacyBackfill.new.call[:inserted_pairs]).to eq(0)
      expect(preparation_locks).to match_array(%w[ schools teachers classrooms teacher_classrooms ])
      raise ActiveRecord::Rollback
    end

    expect(other.get_last_result.cmd_status).to eq("LOCK TABLE")
  ensure
    # Closing also rolls back if an assertion failed while the query was pending.
    other&.close
  end

  it "diagnoses a timeout without retrying or leaking partial locks or the local timeout" do
    school = School.create!(school_code: "FIXTURE#{SecureRandom.hex(4)}")
    with_other_transaction do |other|
      # The final table makes preparation acquire three locks before timing out.
      other.exec("LOCK TABLE teacher_classrooms IN SHARE UPDATE EXCLUSIVE MODE")
      connection.execute("SET LOCAL lock_timeout = '137ms'")
      connection.execute("SET LOCAL statement_timeout = '3s'")
      original_timeout = connection.select_value("SHOW lock_timeout")
      expect(self).to receive(:warn).with(include("LegacyBackfill fixture lock timeout:", "teacher_classrooms"))
      allow(connection).to receive(:execute).and_call_original
      expect(connection).to receive(:execute).with("SET LOCAL lock_timeout = '100ms'").once.and_call_original
      expect(connection).to receive(:execute).with(/\ALOCK TABLE .* IN SHARE UPDATE EXCLUSIVE MODE\z/).once.and_call_original

      expect { prepare_legacy_backfill_fixture(lock_timeout_ms: 100) }.to raise_error(ActiveRecord::LockWaitTimeout)

      expect(connection.select_value("SHOW lock_timeout")).to eq(original_timeout)
      expect(connection.select_value("SELECT 1")).to eq(1)
      expect(preparation_locks).to be_empty
      expect(School.find(school.id).attributes).to eq(school.attributes)
      expect(TeacherClassroom.count).to eq(0)
    end
  end

  it "leaves the unprepared service's immediate maintenance-lock rejection intact" do
    connection.execute("SET LOCAL lock_timeout = '2s'")
    with_other_transaction do |other|
      other.exec("LOCK TABLE schools IN SHARE UPDATE EXCLUSIVE MODE")

      expect { TeacherClassrooms::LegacyBackfill.new.call }.to raise_error(ActiveRecord::LockWaitTimeout,
        /could not obtain lock on relation "schools"/)
      expect(TeacherClassroom.count).to eq(0)
    end
  end

  it "refuses use outside an outer fixture transaction" do
    allow(connection).to receive(:transaction_open?).and_return(false)
    expect(connection).not_to receive(:execute)

    expect { prepare_legacy_backfill_fixture }.to raise_error(/outer fixture transaction/)
  end

  [ 1, 2_000 ].each do |timeout|
    it "accepts the timeout boundary of #{timeout}ms and restores the original value" do
      # Pre-acquire the same locks so a 1ms bound is not sensitive to autovacuum.
      prepare_legacy_backfill_fixture
      connection.execute("SET LOCAL lock_timeout = '137ms'")
      original_timeout = connection.select_value("SHOW lock_timeout")

      prepare_legacy_backfill_fixture(lock_timeout_ms: timeout)

      expect(connection.select_value("SHOW lock_timeout")).to eq(original_timeout)
      expect(preparation_locks).to match_array(%w[ schools teachers classrooms teacher_classrooms ])
    end
  end

  [ 0, -1, 2_001, 1.5, nil, "100" ].each do |timeout|
    it "rejects an unbounded or invalid timeout of #{timeout.inspect}" do
      expect(connection).not_to receive(:execute)

      expect { prepare_legacy_backfill_fixture(lock_timeout_ms: timeout) }.to raise_error(ArgumentError,
        "Bounded fixture timeout required")
    end
  end
end
