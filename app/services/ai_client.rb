class AiClient
  # Preserve the existing model unless the operator explicitly configures another one.
  DEFAULT_MODEL = "gpt-6-astra"
  DEFAULT_TIMEOUT_SECONDS = 120

  def self.model(task)
    model = ENV.fetch("OPENAI_#{task.to_s.upcase}_MODEL") do
      ENV.fetch("OPENAI_MODEL", DEFAULT_MODEL)
    end
    raise "OpenAI model is not configured" if model.blank?

    model
  end

  def self.build(api_key: nil)
    api_key ||= Rails.application.credentials.dig(:openai, :api_key)
    raise "OpenAI API key is not configured" if api_key.blank?

    timeout = Float(ENV.fetch("OPENAI_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS), exception: false)
    unless timeout && timeout.finite? && timeout.positive?
      raise "OpenAI timeout must be a positive number of seconds"
    end

    OpenAI::Client.new(api_key: api_key, max_retries: 0, timeout: timeout)
  end
end
