
class AnswerReadingJob < ApplicationJob
  queue_as :default

  def perform(submission)
    submission.update!(status: :grading)

    result = AnswerReader.new.call(submission)
    data = JSON.parse(result)

    unless data.is_a?(Hash) && data["problems"].is_a?(Array) &&
        data["problems"].any? &&
        data["problems"].all? { |problem| valid_problem?(problem) }
      raise "Invalid answer reading result"
    end

    submission.update!(extracted_text: JSON.generate(data))
  rescue StandardError => e
    submission.update!(status: :failed)
    Rails.logger.error("AnswerReadingJob failed: #{e.class}: #{e.message}")
  end

  private

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
