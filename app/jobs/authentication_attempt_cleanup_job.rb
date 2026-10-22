class AuthenticationAttemptCleanupJob < ApplicationJob
  queue_as :default

  def perform
    # Bound each run; never touch live counters or account/learning records.
    AuthenticationAttemptBucket.where(expires_at: ...Time.current)
      .order(:expires_at).limit(1000).delete_all
  end
end
