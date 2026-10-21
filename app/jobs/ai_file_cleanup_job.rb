class AiFileCleanupJob < ApplicationJob
  queue_as :default

  MAX_ATTEMPTS = 5
  RETRY_DELAYS = [ 1.minute, 3.minutes, 10.minutes, 20.minutes ].freeze

  def self.schedule(file_id)
    return if file_id.blank?

    log_failure(file_id, "enqueue_rejected") unless perform_later(file_id)
  rescue StandardError => error
    log_failure(file_id, "enqueue_error", error.class)
  end

  def perform(file_id, attempt = 1)
    result = AiClient.build.files.delete(file_id)
    return if result.deleted == true

    retry_or_log(file_id, attempt, "delete_not_confirmed")
  rescue OpenAI::Errors::NotFoundError
    # Already deleted/expired is harmless, but an inaccessible file is indistinguishable here.
    Rails.logger.warn("AI file cleanup uncertain: file_id=#{file_id} not_found_or_inaccessible")
  rescue StandardError => error
    retry_or_log(file_id, attempt, "delete_error", error.class)
  end

  private

  def retry_or_log(file_id, attempt, reason, error_class = nil)
    if attempt < MAX_ATTEMPTS
      unless self.class.set(wait: RETRY_DELAYS.fetch(attempt - 1)).perform_later(file_id, attempt + 1)
        self.class.log_failure(file_id, "retry_enqueue_rejected", error_class)
      end
    else
      self.class.log_failure(file_id, "final_#{reason}", error_class)
    end
  rescue StandardError => error
    self.class.log_failure(file_id, "retry_enqueue_error", error.class)
  end

  def self.log_failure(file_id, reason, error_class = nil)
    Rails.logger.error("AI file cleanup failed: file_id=#{file_id} reason=#{reason} error_class=#{error_class}")
  rescue StandardError
    nil
  end
end
