class AddProcessingClaimToSubmissions < ActiveRecord::Migration[8.1]
  def change
    add_column :submissions, :processing_claim_stage, :string
    add_column :submissions, :processing_claim_token, :string
    add_column :submissions, :processing_claimed_at, :datetime
  end
end
