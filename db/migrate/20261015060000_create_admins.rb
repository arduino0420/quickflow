class CreateAdmins < ActiveRecord::Migration[8.1]
  def change
    create_table :admins, id: :bigint do |t|
      t.references :school, type: :bigint, null: false, foreign_key: true
      t.string :user_id, null: false
      t.string :password_digest, null: false

      t.timestamps
    end

    add_index :admins, :user_id, unique: true
  end
end
