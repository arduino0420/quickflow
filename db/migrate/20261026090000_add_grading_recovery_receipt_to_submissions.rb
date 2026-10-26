class AddGradingRecoveryReceiptToSubmissions < ActiveRecord::Migration[8.1]
  def change
    add_column :submissions, :grading_recovery_attempts, :integer, default: 0, null: false
    add_column :submissions, :grading_recovery_requested_at, :datetime
    add_column :submissions, :grading_recovery_state, :string
  end
end
