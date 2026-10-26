# Retry only an explicit HTTP 5xx response, never an unknown transport outcome.
# One extra request TOTAL across upload + reading; no SDK or job retry layer.
class AnswerReadingRequest
  class DeadlineExceeded < StandardError; end
  class OwnershipLost < StandardError; end

  BACKOFF_SECONDS = 1.0

  def initialize(retry_allowed: nil, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, sleeper: ->(seconds) { sleep(seconds) })
    @retry_allowed, @clock, @sleeper = retry_allowed, clock, sleeper
    @timeout = AiClient.timeout_seconds
    # Preserve the old two-request worst-case budget, including one backoff.
    @deadline = @clock.call + 2 * @timeout + BACKOFF_SECONDS
    @retries = 0
  end

  def call(stage)
    raise ArgumentError, "Unknown reading API stage" unless %w[upload reading].include?(stage)

    attempt = 1
    loop do
      raise OwnershipLost if @retry_allowed && !@retry_allowed.call
      remaining = @deadline - @clock.call
      raise DeadlineExceeded unless remaining.positive?

      begin
        return yield(max_retries: 0, timeout: [ @timeout, remaining ].min)
      rescue OpenAI::Errors::APIError, Timeout::Error => error
        retrying = error.is_a?(OpenAI::Errors::InternalServerError) &&
          error.status.is_a?(Integer) && (500..599).cover?(error.status) && @retries.zero? &&
          @retry_allowed && @retry_allowed.call && @deadline - @clock.call > BACKOFF_SECONDS
        log_failure(stage, attempt, error, retrying ? "retry_once" : "stop")
        raise unless retrying

        @retries += 1
        @sleeper.call(BACKOFF_SECONDS)
        attempt += 1
      end
    end
  end

  private

  def log_failure(stage, attempt, error, outcome)
    status = error.respond_to?(:status) && error.status.is_a?(Integer) && (100..599).cover?(error.status) ? error.status : "unknown"
    request_id = error.respond_to?(:request_id) ? error.request_id : nil
    request_id = "unavailable" unless request_id.is_a?(String) && request_id.match?(/\Areq_[A-Za-z0-9_-]{1,100}\z/)
    # Never log exception.message/body/headers, URLs, IDs of pupils or PDFs.
    Rails.logger.warn("AnswerReadingAPI stage=#{stage} attempt=#{attempt} status=#{status} request_id=#{request_id} outcome=#{outcome}")
  end
end
