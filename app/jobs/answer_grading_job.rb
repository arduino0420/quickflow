class AnswerGradingJob < ApplicationJob
  include DiscardDeletedRecord

  queue_as :default

  def perform(submission, generation = 0)
    claim = SubmissionProcessingClaim.new(submission, generation, "grading")
    return unless claim.claim

    results = AnswerGrader.new.call(claim.submission, claim.questions)
    unless results.is_a?(Array) && results.map { |attributes| attributes[:question]&.id || attributes[:question_id] }.sort == claim.questions.map(&:id).sort
      raise "Incomplete grading results"
    end

    claim.finalize do |current|
      results.each { |attributes| current.grading_results.create!(attributes) }
      current.update!(status: :completed)
    end
  rescue StandardError => error
    claim&.fail
    Rails.logger.error("AnswerGradingJob failed: submission_id=#{submission.id} #{error.class}")
  end
end
