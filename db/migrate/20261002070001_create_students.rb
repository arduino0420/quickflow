class CreateStudents < ActiveRecord::Migration[8.1]
  def change
    create_table :students, id: :bigint do |t|
      t.references :classroom, type: :bigint, null: false, foreign_key: true, index: true
      t.integer :attendance_number, null: false
      t.string :password_digest, null: false

      t.timestamps
    end

    add_index :students, [ :classroom_id, :attendance_number ], unique: true
  end
end
