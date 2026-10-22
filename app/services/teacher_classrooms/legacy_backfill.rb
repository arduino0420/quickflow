module TeacherClassrooms
  # One-time migration support while classrooms.teacher_id remains authoritative.
  # Use SQL rather than application models so future callbacks/validations cannot
  # silently change the migration. Never run after relationship editing is enabled:
  # doing so would restore relationships deliberately removed by an operator.
  class LegacyBackfill
    class InconsistentData < StandardError; end
    class VerificationFailed < StandardError; end

    def call
      ActiveRecord::Base.transaction(requires_new: true) do
        connection = ActiveRecord::Base.connection
        # Serialize backfills and freeze both school membership and relationship
        # writes through verification. Ordinary SELECTs remain available. Fail
        # immediately if another transaction is already writing these tables.
        connection.execute("LOCK TABLE schools, teachers, classrooms, teacher_classrooms IN SHARE ROW EXCLUSIVE MODE NOWAIT")
        audit!(connection)
        expected = connection.select_value("SELECT COUNT(*) FROM classrooms").to_i
        inserted = connection.exec_query(<<~SQL).rows.length
          INSERT INTO teacher_classrooms (teacher_id, classroom_id, created_at, updated_at)
          SELECT teacher_id, id, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP FROM classrooms
          ON CONFLICT (teacher_id, classroom_id) DO NOTHING
          RETURNING id
        SQL
        verify!(connection)

        { legacy_pairs: expected, inserted_pairs: inserted, already_present_pairs: expected - inserted,
          total_pairs: connection.select_value("SELECT COUNT(*) FROM teacher_classrooms").to_i }
      end
    end

    private

    def audit!(connection)
      invalid_legacy = connection.select_value(<<~SQL).to_i
        SELECT COUNT(*) FROM classrooms c
        LEFT JOIN teachers t ON t.id = c.teacher_id
        LEFT JOIN schools s ON s.id = c.school_id
        WHERE t.id IS NULL OR s.id IS NULL OR t.school_id IS DISTINCT FROM c.school_id
      SQL
      invalid_existing = connection.select_value(<<~SQL).to_i
        SELECT COUNT(*) FROM teacher_classrooms tc
        LEFT JOIN teachers t ON t.id = tc.teacher_id
        LEFT JOIN classrooms c ON c.id = tc.classroom_id
        LEFT JOIN schools s ON s.id = c.school_id
        WHERE t.id IS NULL OR c.id IS NULL OR s.id IS NULL OR t.school_id IS DISTINCT FROM c.school_id
      SQL
      return if invalid_legacy.zero? && invalid_existing.zero?

      raise InconsistentData, "担当情報に不整合があります。コピーを中止しました（旧担当: #{invalid_legacy}件、既存中間レコード: #{invalid_existing}件）。"
    end

    def verify!(connection)
      missing = connection.select_value(<<~SQL).to_i
        SELECT COUNT(*) FROM (
          SELECT teacher_id, id AS classroom_id FROM classrooms
          EXCEPT
          SELECT teacher_id, classroom_id FROM teacher_classrooms
        ) missing_pairs
      SQL
      raise VerificationFailed, "教師IDとクラスIDの組み合わせが一致しません。コピーを取り消しました。" unless missing.zero?
    end
  end
end
