class CreateAssignmentClassrooms < ActiveRecord::Migration[8.1]
  def change
    create_table :assignment_classrooms, id: :bigint do |t|
      t.references :assignment, type: :bigint, null: false, foreign_key: true, index: true
      t.references :classroom, type: :bigint, null: false, foreign_key: true, index: true

      t.timestamps
    end

    add_index :assignment_classrooms, [ :assignment_id, :classroom_id ], unique: true
  end
end
