class AllowNullLegacyClassroomTeacher < ActiveRecord::Migration[8.1]
  def up
    change_column_null :classrooms, :teacher_id, true
  end

  def down
    # Multiple/zero teachers cannot be represented safely by the legacy column.
    raise ActiveRecord::IrreversibleMigration, "担当関係の切替後は旧カラムへ自動的に戻せません"
  end
end
