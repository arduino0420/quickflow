require "digest"

# NULL admission is deliberately unknown legacy work. Only actual submission and
# the existing explicit grading recovery admit ready work; elapsed time never does.
class SubmissionProcessingClaim
  attr_reader :submission, :questions, :token, :snapshot

  def initialize(submission, generation, stage, admission: nil, question_generation: nil)
    @id, @generation, @stage = submission.id, generation, stage
    @expected_admission, @question_generation = admission, question_generation
  end

  def claim
    locked do |owner, current|
      next unless eligible?(current) && current.processing_claim_stage == "ready"
      next unless generation_authorized?(owner)
      next if @expected_admission && admission_fingerprint(owner, current) != @expected_admission

      # Waiting for shared questions must not consume a grading claim.
      if @stage == "grading"
        validation_snapshot = admission_inputs(owner, current)
        begin
          AnswerGrader.reading_problems(current.extracted_text)
          @questions = QuestionGenerator.new.saved_questions(owner)
        rescue StandardError => error
          @validation_error = error
          current.reload
          owner.reload
          if eligible?(current) && current.processing_claim_stage == "ready" &&
              admission_inputs(owner, current) == validation_snapshot
            current.update!(status: :failed)
          end
          next
        end
        if @questions.empty?
          if QuestionGenerator.new.failed?(owner)
            current.update!(status: :failed)
          else
            current.update!(status: :grading)
          end
          next
        end
      end
      # Force the attachment and blob associations into this captured object.
      current.answer_file.blob
      @submission = current
      @snapshot = inputs(owner, current)
      @token = SecureRandom.uuid
      current.update!(status: :grading, processing_claim_stage: @stage,
        processing_claim_token: @token, processing_claimed_at: Time.current)
      @claimed_at = current.processing_claimed_at
    end
    raise @validation_error if @validation_error

    self if token
  end

  def finalize(admission_stage: nil)
    locked(scope: admission_stage || @stage) do |owner, current|
      next unless owned?(owner, current)

      yield current, owner
    end
  end

  def fail
    finalize { |current| current.update!(status: :failed) }
  rescue ActiveRecord::RecordNotFound
    nil
  end

  # Retain the last reading token in ready state. It identifies this enqueue
  # admission even if another reading worker later returns identical text.
  def self.admission_snapshot(id, generation, stage:)
    current = Submission.find_by(id: id)
    return unless current

    capture = new(current, generation, stage)
    result = nil
    capture.send(:locked) do |owner, row|
      if capture.send(:eligible?, row) && row.processing_claim_stage == "ready"
        result = ready_admission(owner, row, stage: stage)
      end
    end
    result
  end

  def self.fail_ready(id, generation, snapshot:, stage:, question_generation: nil)
    return unless snapshot

    current = Submission.find_by(id: id)
    return unless current

    capture = new(current, generation, stage, question_generation: question_generation)
    capture.send(:locked) do |owner, row|
      if capture.send(:eligible?, row) && row.processing_claim_stage == "ready" &&
          capture.send(:generation_authorized?, owner) && capture.send(:admission_fingerprint, owner, row) == snapshot
        row.update!(status: :failed)
      end
    end
  end

  # Opaque queue arguments prevent reading/PDF payloads entering Active Job logs.
  # Call with the owner/submission still locked in the transition transaction.
  def self.ready_admission(owner, row, stage:)
    new(row, row.processing_generation, stage).send(:admission_fingerprint, owner, row)
  end

  def self.question_generation_authorization(owner, request)
    return unless request.state == "succeeded" && request.selected_input?(owner)

    data = [ request.attributes.slice("id", "assignment_id", "material_blob_id", "model", "prompt_version", "state", "claim_token"),
      owner.teacher_id, owner.current_question_generation_request_id, owner.material_file_attachment&.id,
      owner.material_file.blob&.attributes&.slice("id", "key", "checksum", "byte_size", "service_name", "content_type") ]
    { "request_id" => request.id, "fingerprint" => Digest::SHA256.hexdigest(JSON.generate(data)) }
  end

  def self.ready_attributes
    { processing_claim_stage: "ready", processing_claim_token: nil, processing_claimed_at: nil }
  end

  private

  def locked(scope: @stage)
    # All paths share deletion's parent-before-child order and fresh objects.
    initial = Submission.find_by(id: @id)
    return unless initial

    Assignment.transaction(requires_new: true) do
      owner = Assignment.lock("FOR NO KEY UPDATE").find_by(id: initial.assignment_id)
      next unless owner

      if @question_generation
        @source_request = owner.question_generation_requests.lock.find_by(id: @question_generation["request_id"])
        next unless @source_request
      end
      current = Submission.lock.find_by(id: @id)
      next unless current && current.assignment_id == owner.id

      owner.questions.order(:id).lock.load if scope == "grading"
      attachment_ids = [ current.answer_file_attachment&.id ]
      attachment_ids << owner.material_file_attachment&.id if scope == "grading"
      attachments = ActiveStorage::Attachment.where(id: attachment_ids.compact).order(:id).lock.to_a
      ActiveStorage::Blob.where(id: attachments.map(&:blob_id)).order(:id).lock("FOR SHARE").load
      yield owner, current
    end
  end

  def eligible?(current)
    current.processing_generation == @generation && !current.completed? && !current.failed? &&
      !current.grading_results.exists?
  end

  def owned?(owner, current)
    eligible?(current) && generation_authorized?(owner) && current.grading? && current.processing_claim_stage == @stage &&
      current.processing_claim_token == token && current.processing_claimed_at == @claimed_at && token.present? && inputs(owner, current) == snapshot
  end

  def generation_authorized?(owner)
    !@question_generation || (@source_request &&
      self.class.question_generation_authorization(owner, @source_request) == @question_generation)
  end

  def admission_fingerprint(owner, row)
    data = [ @stage, row.processing_generation, row.processing_claim_stage,
      row.processing_claimed_at&.iso8601(6), admission_inputs(owner, row) ]
    Digest::SHA256.hexdigest(JSON.generate(data))
  end

  def admission_inputs(owner, row)
    [ row.status, row.processing_claim_token, row.processing_claimed_at&.iso8601(6), inputs(owner, row) ]
  end

  def attachment_state(attachment)
    return unless attachment

    blob = attachment.blob
    [ attachment.id, attachment.blob_id, blob.key, blob.service_name, blob.checksum, blob.byte_size ]
  end

  def inputs(owner, current)
    state = [ current.assignment_id, current.student_id, owner.teacher_id, current.extracted_text,
      attachment_state(current.answer_file_attachment) ]
    if @stage == "grading"
      state += [ owner.teacher_id, owner.current_question_generation_request_id,
        attachment_state(owner.material_file_attachment),
        owner.questions.order(:position, :id).map { |question|
          question.attributes.except("created_at", "updated_at")
        } ]
    end
    state
  end
end
