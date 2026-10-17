if ENV["QUICKFLOW_HTTP_LOAD_RUN_ID"].present?
  raise "HTTP load guard requires test environment" unless Rails.env.test?
  raise "SOLID_QUEUE_IN_PUMA is forbidden" if ENV["SOLID_QUEUE_IN_PUMA"].present?
  raise "OpenAI key is forbidden" if ENV.keys.any? { |key| key.match?(/OPENAI.*(KEY|TOKEN)|^(?:RAILS_MASTER_KEY|QUICKFLOW_DATABASE_PASSWORD)$/) }

  require "active_job/queue_adapters/test_adapter"
  require "json"

  class HttpLoadJobRecordError < StandardError; end

  class HttpLoadRecordingAdapter < ActiveJob::QueueAdapters::TestAdapter
    def initialize(path)
      super()
      @path = path
      self.perform_enqueued_jobs = false
      self.perform_enqueued_at_jobs = false
    end

    def enqueue(job)
      super
      record(job)
    end

    def enqueue_at(job, timestamp)
      super
      record(job)
    end

    private

    def record(job)
      submission_id = job.arguments.first.id if job.arguments.first.is_a?(Submission)
      row = { job_id: job.job_id, job_type: job.class.name, submission_id: submission_id }
      File.open(@path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
        file.flock(File::LOCK_EX)
        file.puts(JSON.generate(row))
        file.flush
        file.fsync
      ensure
        file.flock(File::LOCK_UN)
      end
    rescue StandardError => error
      raise HttpLoadJobRecordError, error.class.name
    end
  end

  Rails.application.config.action_controller.allow_forgery_protection = true
  Rails.application.config.active_storage.service = :test
  ActiveSupport.on_load(:action_controller_base) { self.allow_forgery_protection = true }
  Rails.application.config.active_job.queue_adapter = HttpLoadRecordingAdapter.new(
    Rails.root.join("tmp", "http_load_jobs_#{ENV.fetch('QUICKFLOW_HTTP_LOAD_RUN_ID')}.jsonl")
  )
  ActiveJob::Base.prepend(Module.new do
    def perform_now
      raise "Job execution forbidden in HTTP load trial"
    end
  end)
end
