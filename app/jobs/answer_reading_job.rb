
class AnswerReadingJob < ApplicationJob
  queue_as :default

  def perform(submission)
    ready = false
    submission.with_lock do
      next if submission.completed? || submission.failed?

      begin
        submission.update!(status: :grading)
        if submission.extracted_text.blank?
          result = AnswerReader.new.call(submission)
          data = JSON.parse(result)

          unless data.is_a?(Hash) && data["problems"].is_a?(Array) &&
              data["problems"].any? &&
              data["problems"].all? { |problem| valid_problem?(problem) }
            raise "Invalid answer reading result"
          end

          submission.update!(extracted_text: JSON.generate(data))
        end
        ready = true
      rescue StandardError => error
        submission.update!(status: :failed)
        Rails.logger.error("AnswerReadingJob failed: #{error.class}: #{error.message}")
      end
    end

    enqueue_grading(submission) if ready
  rescue StandardError => e
    submission.with_lock { submission.update!(status: :failed) unless submission.completed? || submission.failed? }
    Rails.logger.error("AnswerReadingJob failed: #{e.class}: #{e.message}")
  end

  private

  def enqueue_grading(submission)
    submission.with_lock do
      next if submission.completed? || submission.failed?

      begin
        raise "Could not enqueue answer grading" unless AnswerGradingJob.perform_later(submission)
      rescue StandardError => error
        submission.update!(status: :failed) unless submission.completed? || submission.failed?
        Rails.logger.error("AnswerReadingJob grading enqueue failed: submission_id=#{submission.id} #{error.class}")
      end
    end
  end

  def valid_problem?(problem)
    return false unless problem.is_a?(Hash)

    required_keys = %w[
      question_label
      question_text
      student_answer
      reading_status
      reading_reason
    ]

    return false unless required_keys.all? { |key| problem.key?(key) }

    %w[readable blank unclear ambiguous unavailable].include?(
      problem["reading_status"]
    )
  end
end
