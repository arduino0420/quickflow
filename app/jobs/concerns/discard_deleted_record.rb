module DiscardDeletedRecord
  extend ActiveSupport::Concern

  included do
    before_perform { |job| job.arguments.first.reload }

    discard_on ActiveJob::DeserializationError do |_job, error|
      raise error unless error.cause.is_a?(ActiveRecord::RecordNotFound)
    end
    rescue_from ActiveRecord::RecordNotFound do |error|
      record = arguments.first
      raise error unless record.is_a?(ActiveRecord::Base) && !record.class.exists?(record.id)
    end
  end
end
