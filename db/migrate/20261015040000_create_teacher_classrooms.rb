class CreateTeacherClassrooms < ActiveRecord::Migration[8.1]
  def change
    create_table :teacher_classrooms, id: :bigint do |t|
      t.references :teacher, type: :bigint, null: false, foreign_key: true, index: false
      t.references :classroom, type: :bigint, null: false, foreign_key: true, index: true

      t.timestamps
    end

    add_index :teacher_classrooms, [ :teacher_id, :classroom_id ], unique: true
  end
end
