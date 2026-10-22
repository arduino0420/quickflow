# NULL admission is deliberately unknown legacy work. Only actual submission and
# the existing explicit grading recovery admit ready work; elapsed time never does.
class SubmissionProcessingClaim
  attr_reader :submission, :questions, :token, :snapshot

  def initialize(submission, generation, stage)
    @id, @generation, @stage = submission.id, generation, stage
  end

  def claim
    locked do |owner, current|
      next unless eligible?(current) && current.processing_claim_stage == "ready"

      # Waiting for shared questions must not consume a grading claim.
      if @stage == "grading"
        validation_snapshot = admission_inputs(owner, current)
        begin
          AnswerGrader.reading_problems(current.extracted_text)
          @questions = QuestionGenerator.new.saved_questions(owner)
        rescue StandardError
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
    self if token
  end

  def finalize
    locked do |owner, current|
      next unless owned?(owner, current)

      yield current
    end
  end

  def fail
    finalize { |current| current.update!(status: :failed) }
  rescue ActiveRecord::RecordNotFound
    nil
  end

  # Retain the last reading token in ready state. It identifies this enqueue
  # admission even if another reading worker later returns identical text.
  def self.admission_snapshot(id, generation)
    current = Submission.find_by(id: id)
    return unless current

    capture = new(current, generation, "enqueue")
    result = nil
    capture.send(:locked) do |owner, row|
      if capture.send(:eligible?, row) && row.processing_claim_stage == "ready"
        result = capture.send(:admission_inputs, owner, row)
      end
    end
    result
  end

  def self.fail_ready(id, generation, snapshot:)
    return unless snapshot

    current = Submission.find_by(id: id)
    return unless current

    capture = new(current, generation, "enqueue")
    capture.send(:locked) do |owner, row|
      if capture.send(:eligible?, row) && row.processing_claim_stage == "ready" &&
          capture.send(:admission_inputs, owner, row) == snapshot
        row.update!(status: :failed)
      end
    end
  end

  def self.ready_attributes
    { processing_claim_stage: "ready", processing_claim_token: nil, processing_claimed_at: nil }
  end

  private

  def locked
    # All paths share deletion's parent-before-child order and fresh objects.
    initial = Submission.find_by(id: @id)
    return unless initial

    Assignment.transaction(requires_new: true) do
      owner = Assignment.lock("FOR NO KEY UPDATE").find_by(id: initial.assignment_id)
      next unless owner

      current = Submission.lock.find_by(id: @id)
      next unless current && current.assignment_id == owner.id

      owner.questions.order(:id).lock.load if @stage == "grading"
      attachment_ids = [ current.answer_file_attachment&.id ]
      attachment_ids << owner.material_file_attachment&.id if @stage == "grading"
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
    eligible?(current) && current.grading? && current.processing_claim_stage == @stage &&
      current.processing_claim_token == token && current.processing_claimed_at == @claimed_at && token.present? && inputs(owner, current) == snapshot
  end

  def admission_inputs(owner, row)
    [ row.status, row.processing_claim_token, row.processing_claimed_at, inputs(owner, row) ]
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
