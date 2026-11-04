# Test-fixture preparation only. The service must retain its NOWAIT guard.
module LegacyBackfillFixture
  TABLES = %w[ schools teachers classrooms teacher_classrooms ].freeze

  def prepare_legacy_backfill_fixture(lock_timeout_ms: 2_000)
    connection = ActiveRecord::Base.connection
    raise "An outer fixture transaction is required" unless connection.transaction_open?
    raise ArgumentError, "Bounded fixture timeout required" unless lock_timeout_ms.is_a?(Integer) && (1..2_000).cover?(lock_timeout_ms)

    connection.transaction(requires_new: true) do
      original_timeout = connection.select_value("SHOW lock_timeout")
      connection.execute("SET LOCAL lock_timeout = #{connection.quote("#{lock_timeout_ms}ms")}")
      tables = TABLES.map { |table| connection.quote_table_name(table) }
      # Match the service's table order. This excludes autovacuum's maintenance
      # lock, but allows the deliberate ROW EXCLUSIVE writer in the NOWAIT spec.
      # PostgreSQL applies lock_timeout to each acquisition, not all four combined.
      connection.execute("LOCK TABLE #{tables.join(', ')} IN SHARE UPDATE EXCLUSIVE MODE")
      connection.execute("SET LOCAL lock_timeout = #{connection.quote(original_timeout)}")
      # Releasing this savepoint retains the locks until the outer fixture rolls back.
    end
  rescue ActiveRecord::LockWaitTimeout
    # The failed savepoint has rolled back both partial locks and SET LOCAL.
    report_legacy_backfill_fixture_locks(connection)
    raise
  end

  def report_legacy_backfill_fixture_locks(connection)
    relations = TABLES.map { |table| "#{connection.quote(table)}::regclass" }.join(", ")
    locks = connection.select_all(<<~SQL).to_a
      SELECT l.pid, l.relation::regclass::text AS relation, l.mode, l.granted,
             a.backend_type, a.state
      FROM pg_locks l
      LEFT JOIN pg_stat_activity a ON a.pid = l.pid
      WHERE l.locktype = 'relation' AND l.relation IN (#{relations})
      ORDER BY l.relation, l.pid, l.mode
    SQL
    warn "LegacyBackfill fixture lock timeout: #{JSON.generate(current_pid: connection.select_value('SELECT pg_backend_pid()'), locks: locks)}"
  rescue StandardError => error
    warn "LegacyBackfill fixture lock diagnostics unavailable: #{error.class}"
  end
end
