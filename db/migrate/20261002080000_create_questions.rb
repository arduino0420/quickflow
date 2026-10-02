class CreateQuestions < ActiveRecord::Migration[8.1]
  def change
    create_table :questions, id: :bigint do |t|
      t.references :assignment, type: :bigint, null: false, foreign_key: true, index: false
      t.string :question_label, null: false
      t.integer :position, null: false
      t.text :question_text, null: false
      t.text :correct_answer, null: false
      t.text :grading_rule
      t.string :answer_generation_model, null: false
      t.string :answer_generation_prompt_version, null: false
      t.datetime :answer_generated_at, null: false

      t.timestamps
    end

    add_index :questions, [ :assignment_id, :position ], unique: true
  end
end
