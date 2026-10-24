# Test-fixture preparation only. The operator task must retain its NOWAIT guard.
module DemoSeedFixture
  def prepare_demo_seed_fixture(seed: Demo::Seed.new, lock_timeout_ms: 2_000)
    with_demo_seed_fixture_locks(lock_timeout_ms: lock_timeout_ms) { seed.call }
  end

  def with_demo_seed_fixture_locks(lock_timeout_ms: 2_000)
    connection = ApplicationRecord.connection
    raise "An outer fixture transaction is required" unless connection.transaction_open?
    raise ArgumentError, "Bounded fixture timeout required" unless lock_timeout_ms.is_a?(Integer) && (1..2_000).cover?(lock_timeout_ms)

    connection.transaction(requires_new: true) do
      original_timeout = connection.select_value("SHOW lock_timeout")
      connection.execute("SET LOCAL lock_timeout = #{connection.quote("#{lock_timeout_ms}ms")}")
      tables = Demo::Seed::TABLE_MODELS.map { |model| connection.quote_table_name(model.table_name) }
      connection.execute("LOCK TABLE #{tables.join(', ')} IN EXCLUSIVE MODE")
      connection.execute("SET LOCAL lock_timeout = #{connection.quote(original_timeout)}")
      # The same connection retains these locks through the outer fixture transaction.
      yield
    end
  rescue ActiveRecord::LockWaitTimeout
    # requires_new has rolled back the failed savepoint, so this connection is usable.
    report_demo_fixture_locks(connection)
    raise
  end

  def report_demo_fixture_locks(connection)
    names = Demo::Seed::TABLE_MODELS.map { |model| connection.quote(model.table_name) }.join(", ")
    locks = connection.select_all(<<~SQL).to_a
      SELECT a.pid, a.backend_type, a.state, a.application_name,
        a.xact_start::text, l.relation::regclass::text AS relation, l.mode, l.granted
      FROM pg_locks l JOIN pg_stat_activity a ON a.pid = l.pid
      WHERE l.relation IN (SELECT oid FROM pg_class WHERE relname IN (#{names}))
      ORDER BY a.pid, l.relation, l.mode
    SQL
    vacuum = connection.select_all("SELECT pid, datname, relid::regclass::text AS relation, phase FROM pg_stat_progress_vacuum WHERE datname = current_database()").to_a
    warn "Demo fixture lock timeout: #{JSON.generate(locks: locks, vacuum: vacuum)}"
  rescue ActiveRecord::ActiveRecordError => error
    warn "Demo fixture lock diagnostics unavailable: #{error.class}"
  end
end
