class QuestionGenerationJob < ApplicationJob
  include DiscardDeletedRecord

  queue_as :default

  def perform(assignment, material_blob_id, generation = 0, request_id: nil)
    # Old queued jobs have no immutable identity. They must never infer fresh intent.
    return unless request_id

    assignment.reload
    owner_id = assignment.teacher_id
    request = assignment.question_generation_requests.find_by(id: request_id)
    return unless request && request.material_blob_id == material_blob_id && request.selected_input?(assignment)
    return if request.state == "failed"

    initial_token = request.claim_token
    begin
      generator = QuestionGenerator.new(model: request.model)
      questions = generator.call(assignment, material_blob_id: material_blob_id, request_id: request_id)
      return unless questions&.any?
    rescue StandardError => error
      Rails.logger.error("QuestionGenerationJob failed: #{error.class}")
      return unless generator&.failure_recorded

      fan_out(request, material_blob_id, generation, owner_id: owner_id, state: "failed", token: generator.claim_token) do |submission|
        submission.update!(status: :failed)
      end
      return
    end

    success_token = generator.claim_token || initial_token
    targets = []
    fan_out(request, material_blob_id, generation, owner_id: owner_id, state: "succeeded", token: success_token) do |submission, owner|
      targets << [ submission.id, SubmissionProcessingClaim.admission_snapshot(submission.id, generation, stage: "grading"),
        SubmissionProcessingClaim.question_generation_authorization(owner, request) ]
    end
    targets.each do |id, snapshot, authorization|
      begin
        submission = Submission.find_by(id: id)
        next unless submission

        raise "Could not enqueue answer grading" unless AnswerGradingJob.perform_later(submission, generation,
          admission: snapshot, question_generation: authorization)
      rescue StandardError => error
        SubmissionProcessingClaim.fail_ready(id, generation, snapshot: snapshot, stage: "grading", question_generation: authorization)
        Rails.logger.error("QuestionGenerationJob grading enqueue failed: #{error.class}")
      end
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  private

  def fan_out(request, blob_id, generation, owner_id:, state:, token:)
    return unless token.present?

    request.with_selected_lock do |assignment|
      next unless assignment.teacher_id == owner_id && request.state == state && request.claim_token == token && request.material_blob_id == blob_id

      assignment.submissions.where(status: [ :submitted, :grading ]).where.not(extracted_text: [ nil, "" ]).find_each do |submission|
        submission.with_lock do
          next if submission.processing_claim_stage != "ready" || submission.processing_generation != generation || submission.completed? || submission.failed? || submission.grading_results.exists?

          yield submission, assignment
        end
      end
    end
  end
end
