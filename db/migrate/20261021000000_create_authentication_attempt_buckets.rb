class CreateAuthenticationAttemptBuckets < ActiveRecord::Migration[8.1]
  def change
    create_table :authentication_attempt_buckets, id: false do |t|
      t.string :key_digest, limit: 64, null: false, primary_key: true
      t.integer :attempts, null: false
      t.datetime :expires_at, null: false
    end
    add_index :authentication_attempt_buckets, :expires_at
  end
end
