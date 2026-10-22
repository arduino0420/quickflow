class QuestionGenerationJob < ApplicationJob
  include DiscardDeletedRecord

  queue_as :default

  def perform(assignment, material_blob_id, generation = 0, request_id: nil)
    # Old queued jobs have no immutable identity. They must never infer fresh intent.
    return unless request_id

    request = assignment.question_generation_requests.find_by(id: request_id)
    return unless request
    return if request.state == "failed"

    generator = QuestionGenerator.new
    begin
      questions = generator.call(assignment, material_blob_id: material_blob_id, request_id: request_id)
      return unless questions&.any?
    rescue StandardError => error
      Rails.logger.error("QuestionGenerationJob failed: #{error.class}")
      fan_out(request, material_blob_id, generation, state: "failed", token: generator.claim_token) do |submission|
        submission.update!(status: :failed)
      end
      return
    end

    fan_out(request, material_blob_id, generation, state: "succeeded", token: request.reload.claim_token) do |submission|
      begin
        raise "Could not enqueue answer grading" unless AnswerGradingJob.perform_later(submission, generation)
      rescue StandardError => error
        submission.reload
        request.reload
        owner = request.assignment.reload
        if request.selected_input?(owner) && request.state == "succeeded" &&
            submission.processing_generation == generation && !submission.completed? && !submission.failed? && !submission.grading_results.exists?
          submission.update!(status: :failed)
        end
        Rails.logger.error("QuestionGenerationJob grading enqueue failed: #{error.class}")
      end
    end
  end

  private

  def fan_out(request, blob_id, generation, state:, token:)
    return unless token.present?

    request.with_selected_lock do |assignment|
      next unless request.state == state && request.claim_token == token && request.material_blob_id == blob_id

      assignment.submissions.where(status: [ :submitted, :grading ]).where.not(extracted_text: [ nil, "" ]).find_each do |submission|
        submission.with_lock do
          next if submission.processing_generation != generation || submission.completed? || submission.failed? || submission.grading_results.exists?

          yield submission
        end
      end
    end
  end
end
