class CreateAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :assignments, id: :bigint do |t|
      t.references :teacher, type: :bigint, null: false, foreign_key: true, index: true
      t.string :title, null: false
      t.integer :point_per_question, null: false
      t.datetime :published_at

      t.timestamps
    end
  end
end
