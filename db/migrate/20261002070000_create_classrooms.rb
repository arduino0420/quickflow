class CreateClassrooms < ActiveRecord::Migration[8.1]
  def change
    create_table :classrooms, id: :bigint do |t|
      t.references :school, type: :bigint, null: false, foreign_key: true, index: true
      t.references :teacher, type: :bigint, null: false, foreign_key: true, index: true
      t.integer :grade, null: false
      t.integer :class_number, null: false

      t.timestamps
    end

    add_index :classrooms, [ :school_id, :grade, :class_number ], unique: true
  end
end
