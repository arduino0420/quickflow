class QuestionGenerationJob < ApplicationJob
  queue_as :default

  def perform(assignment, material_blob_id)
    generator = QuestionGenerator.new
    begin
      generator.call(assignment, material_blob_id: material_blob_id)
    rescue StandardError => error
      generator.record_failure(assignment)
      # Parser errors can include AI output; diagnostic metadata is logged by the service.
      Rails.logger.error("QuestionGenerationJob failed: #{error.class}")
      readable_submissions(assignment).find_each do |submission|
        submission.with_lock { submission.update!(status: :failed) unless submission.completed? || submission.failed? }
      end
      return
    end

    readable_submissions(assignment).find_each { |submission| enqueue_grading(submission) }
  end

  private

  def enqueue_grading(submission)
    raise "Could not enqueue answer grading" unless AnswerGradingJob.perform_later(submission)
  rescue StandardError => error
    submission.with_lock { submission.update!(status: :failed) unless submission.completed? || submission.failed? }
    Rails.logger.error("QuestionGenerationJob grading enqueue failed: #{error.class}: #{error.message}")
  end

  def readable_submissions(assignment)
    assignment.submissions.where(status: [ :submitted, :grading ]).where.not(extracted_text: [ nil, "" ])
  end
end
