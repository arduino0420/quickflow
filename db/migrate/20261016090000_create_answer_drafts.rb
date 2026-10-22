class CreateAnswerDrafts < ActiveRecord::Migration[8.1]
  def change
    create_table :answer_drafts do |t|
      t.references :student, null: false, foreign_key: true
      t.references :assignment, null: false, foreign_key: true
      t.string :material_fingerprint, null: false, limit: 64
      t.integer :format_version, null: false, default: 1
      t.jsonb :page_data, null: false, default: []
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :answer_drafts, [ :student_id, :assignment_id ], unique: true
  end
end
