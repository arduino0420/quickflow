class CreateQuestionGenerationRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :question_generation_requests do |t|
      t.references :assignment, null: false, foreign_key: true
      t.bigint :material_blob_id, null: false
      t.string :model, null: false
      t.string :prompt_version, null: false
      t.string :state, null: false, default: "pending"
      t.string :claim_token
      t.datetime :started_at
      t.datetime :finished_at
      t.string :failure_code
      t.timestamps
    end
    add_index :question_generation_requests, [ :assignment_id, :material_blob_id, :model, :prompt_version ],
      unique: true, name: "index_question_generation_requests_on_input_scope"
    add_reference :assignments, :current_question_generation_request, null: true,
      foreign_key: { to_table: :question_generation_requests }, index: { name: "index_assignments_on_current_generation_request" }
  end
end
