class CreateTeachers < ActiveRecord::Migration[8.1]
  def change
    create_table :teachers, id: :bigint do |t|
      t.references :school, type: :bigint, null: false, foreign_key: true, index: true
      t.string :user_id, null: false
      t.string :password_digest, null: false

      t.timestamps
    end

    add_index :teachers, :user_id, unique: true
  end
end
