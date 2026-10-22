class CreateSubmissions < ActiveRecord::Migration[8.1]
  def change
    create_table :submissions, id: :bigint do |t|
      t.references :assignment, type: :bigint, null: false, foreign_key: true, index: false
      t.references :student, type: :bigint, null: false, foreign_key: true, index: true
      t.integer :status, null: false, default: 0
      t.datetime :submitted_at, null: false

      t.timestamps
    end

    add_index :submissions, [ :assignment_id, :student_id ], unique: true
  end
end
