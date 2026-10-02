class CreateGradingResults < ActiveRecord::Migration[8.1]
  def change
    create_table :grading_results, id: :bigint do |t|
      t.references :submission, type: :bigint, null: false, foreign_key: true, index: true
      t.references :question, type: :bigint, null: false, foreign_key: true, index: true
      t.text :student_answer
      t.integer :reading_confidence
      t.integer :ai_judgment, null: false
      t.integer :teacher_judgment
      t.text :error_point
      t.text :feedback
      t.text :review_reason
      t.string :model_name, limit: 255, null: false
      t.string :prompt_version, limit: 50, null: false
      t.datetime :graded_at, null: false

      t.timestamps
    end

    add_index :grading_results, [ :submission_id, :question_id ], unique: true
  end
end
