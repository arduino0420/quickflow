class AnswerReadingJob < ApplicationJob
  include DiscardDeletedRecord

  queue_as :default

  def perform(submission, generation = 0)
    claim = SubmissionProcessingClaim.new(submission, generation, "reading")
    return unless claim.claim

    captured = claim.submission
    text = captured.extracted_text
    if text.blank?
      result = AnswerReader.new.call(captured)
      data = JSON.parse(result)
      unless data.is_a?(Hash) && data["problems"].is_a?(Array) && data["problems"].any? &&
          data["problems"].all? { |problem| valid_problem?(problem) }
        raise "Invalid answer reading result"
      end
      text = JSON.generate(data)
    end
    ready = false
    claim.finalize do |current|
      current.update!(processing_claim_stage: "ready", extracted_text: text)
      ready = true
    end
    enqueue_grading(submission.id, generation) if ready
  rescue StandardError => error
    claim&.fail
    Rails.logger.error("AnswerReadingJob failed: submission_id=#{submission.id} #{error.class}")
  end

  private

  def enqueue_grading(id, generation)
    snapshot = SubmissionProcessingClaim.admission_snapshot(id, generation)
    return unless snapshot

    current = Submission.find_by(id: id)
    return unless current

    raise "Could not enqueue answer grading" unless AnswerGradingJob.perform_later(current, generation)
  rescue StandardError => error
    SubmissionProcessingClaim.fail_ready(id, generation, snapshot: snapshot)
    Rails.logger.error("AnswerReadingJob grading enqueue failed: submission_id=#{id} #{error.class}")
  end

  def valid_problem?(problem)
    return false unless problem.is_a?(Hash)

    required_keys = %w[question_label question_text student_answer reading_status reading_reason]
    required_keys.all? { |key| problem.key?(key) } &&
      %w[readable blank unclear ambiguous unavailable].include?(problem["reading_status"])
  end
end
