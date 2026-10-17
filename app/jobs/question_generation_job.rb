class QuestionGenerationJob < ApplicationJob
  include DiscardDeletedRecord

  queue_as :default

  def perform(assignment, material_blob_id, generation = 0)
    generator = QuestionGenerator.new
    begin
      generator.call(assignment, material_blob_id: material_blob_id)
    rescue StandardError => error
      assignment.with_lock("FOR NO KEY UPDATE") do
        generator.record_failure(assignment)
        # Parser errors can include AI output; log only diagnostic metadata.
        Rails.logger.error("QuestionGenerationJob failed: #{error.class}")
        readable_submissions(assignment).find_each do |submission|
          submission.with_lock do
            submission.update!(status: :failed) if submission.processing_generation == generation && !submission.completed? && !submission.failed?
          end
        end
      end
      return
    end

    readable_submissions(assignment).find_each { |submission| enqueue_grading(submission, generation) }
  end

  private

  def enqueue_grading(submission, generation)
    submission.reload
    return if submission.processing_generation != generation || submission.completed? || submission.failed? || submission.grading_results.exists?

    raise "Could not enqueue answer grading" unless AnswerGradingJob.perform_later(submission, generation)
  rescue StandardError => error
    submission.with_lock do
      submission.update!(status: :failed) if submission.processing_generation == generation && !submission.completed? && !submission.failed?
    end
    Rails.logger.error("QuestionGenerationJob grading enqueue failed: #{error.class}: #{error.message}")
  end

  def readable_submissions(assignment)
    assignment.submissions.where(status: [ :submitted, :grading ]).where.not(extracted_text: [ nil, "" ])
  end
end
