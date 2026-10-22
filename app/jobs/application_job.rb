class ApplicationJob < ActiveJob::Base
  before_perform do
    raise Demo::Guest::Unavailable, "Jobs disabled in demo mode" if Demo::Guest.configured?
  end

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError
end
