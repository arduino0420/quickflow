require "digest"

module Recovery
  class GradingEligibility
    RESULT_CANDIDATE = "candidate"
    RESULT_INELIGIBLE = "ineligible"
    RESULT_INDETERMINATE = "indeterminate"
    MAX_SUBMISSION_ID = 9_223_372_036_854_775_807

    Snapshot = Struct.new(:fingerprint, :submission_id, :assignment_id, :status, :generation,
      :problems, :questions, :answer_pdf, :material_pdf, :result_count, :teacher_judgment_present,
      :reason_codes, keyword_init: true)

    def call(submission, expected_status: :failed)
      submission_id = if submission.respond_to?(:id)
        submission.id
      elsif submission.to_s.match?(/\A[1-9][0-9]*\z/)
        submission.to_s.to_i
      end
      unless submission_id.is_a?(Integer) && submission_id.positive? && submission_id <= MAX_SUBMISSION_ID
        return result(RESULT_INELIGIBLE, :invalid_submission_id)
      end

      initial = capture_snapshot(submission_id, expected_status)
      return result(RESULT_INDETERMINATE, :submission_missing) unless initial

      return result(RESULT_INELIGIBLE, *initial.reason_codes) if initial.reason_codes.any?

      [ initial.answer_pdf, initial.material_pdf ].each do |pdf|
        pdf_result = inspect_pdf(pdf)
        return pdf_result unless pdf_result[:result] == RESULT_CANDIDATE
      end

      verify_locked_snapshot(initial, expected_status) { |locked| block_given? ? yield(locked) : nil }
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, PG::LockNotAvailable
      result(RESULT_INDETERMINATE, :database_lock_unavailable)
    rescue ActiveRecord::RecordNotFound
      result(RESULT_INDETERMINATE, :state_changed)
    rescue ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed, ActiveRecord::StatementInvalid
      result(RESULT_INDETERMINATE, :database_unavailable)
    end

    private

    def capture_snapshot(submission_id, expected_status)
      return capture_snapshot_records(submission_id, expected_status) if ActiveRecord::Base.connection.transaction_open?

      Submission.transaction(isolation: :repeatable_read, requires_new: true) do
        capture_snapshot_records(submission_id, expected_status)
      end
    end

    def capture_snapshot_records(submission_id, expected_status)
      submission = Submission.find_by(id: submission_id)
      return unless submission

      assignment = Assignment.find_by(id: submission.assignment_id)
      return unless assignment

      build_snapshot(submission, assignment, expected_status)
    end

    def build_snapshot(submission, assignment, expected_status)
      questions = assignment.questions.order(:position, :id).to_a
      results = submission.grading_results.order(:id).to_a
      answer_attachment = submission.answer_file_attachment
      material_attachment = assignment.material_file_attachment
      answer_pdf = pdf_reference(answer_attachment)
      material_pdf = pdf_reference(material_attachment)
      problems, reading_reason_codes = validated_problems(submission.extracted_text)
      question_reason_codes = validated_questions(assignment, questions, problems)
      reason_codes = []
      reason_codes << :status_not_failed unless submission.status == expected_status.to_s
      reason_codes.concat(reading_reason_codes)
      reason_codes.concat(question_reason_codes)
      reason_codes << :grading_results_present if results.any?
      reason_codes << :teacher_judgment_present if results.any? { |item| item.teacher_judgment_before_type_cast.present? }
      reason_codes << :answer_attachment_missing unless valid_attachment?(answer_attachment, "Submission", submission.id, "answer_file", answer_pdf)
      reason_codes << :material_attachment_missing unless valid_attachment?(material_attachment, "Assignment", assignment.id, "material_file", material_pdf)

      state = {
        submission: [ submission.id, submission.assignment_id, submission.status, submission.processing_generation,
          submission.processing_claim_stage, submission.processing_claim_token, submission.processing_claimed_at&.iso8601(6),
          submission.extracted_text, submission.updated_at&.iso8601(6) ],
        assignment: [ assignment.id, assignment.updated_at&.iso8601(6) ],
        answer_pdf: pdf_state(answer_attachment, answer_pdf),
        material_pdf: pdf_state(material_attachment, material_pdf),
        questions: questions.map { |question| question_state(question) },
        results: results.map { |item| [ item.id, item.question_id, item.teacher_judgment_before_type_cast ] }
      }

      Snapshot.new(fingerprint: Digest::SHA256.hexdigest(JSON.generate(state)),
        submission_id: submission.id, assignment_id: assignment.id, status: submission.status,
        generation: submission.processing_generation, problems: problems, questions: questions,
        answer_pdf: answer_pdf, material_pdf: material_pdf, result_count: results.size,
        teacher_judgment_present: results.any? { |item| item.teacher_judgment_before_type_cast.present? },
        reason_codes: reason_codes.uniq)
    end

    def validated_problems(text)
      problems = AnswerGrader.reading_problems(text)
      invalid = problems.any? do |problem|
        !problem["question_label"].is_a?(String) || problem["question_label"].blank? ||
          !%w[readable blank].include?(problem["reading_status"]) ||
          (problem["reading_status"] == "readable" && (!problem["student_answer"].is_a?(String) || problem["student_answer"].blank?)) ||
          (problem["reading_status"] == "blank" && ![ nil, "" ].include?(problem["student_answer"]))
      end
      return [ nil, [ :reading_state_invalid ] ] if invalid
      return [ problems, [ :reading_question_label_duplicate ] ] unless problems.map { |item| item["question_label"] }.uniq.size == problems.size

      [ problems, [] ]
    rescue JSON::ParserError, RuntimeError, TypeError
      [ nil, [ :reading_json_invalid ] ]
    end

    def validated_questions(assignment, questions, problems)
      return [ :questions_missing ] if questions.empty?

      rules = questions.map { |question| JSON.parse(question.grading_rule.to_s) }
      return [ :saved_questions_invalid ] unless rules.all? { |rule| rule.is_a?(Hash) }
      return [ :material_blob_id_missing ] if rules.any? { |rule| !rule.is_a?(Hash) || !rule.key?("material_blob_id") }

      current_blob_id = assignment.material_file.blob&.id
      return [ :material_blob_missing ] unless current_blob_id
      return [ :material_blob_mismatch ] unless rules.all? { |rule| rule["material_blob_id"] == current_blob_id }

      labels = questions.map(&:question_label)
      return [ :question_label_duplicate ] unless labels.uniq.size == labels.size
      problem_labels = problems&.map { |problem| problem["question_label"] }&.sort
      return [ :reading_question_labels_mismatch ] unless problem_labels == labels.sort

      begin
        validated = QuestionGenerator.new(model: nil).saved_questions(assignment)
      rescue JSON::ParserError, RuntimeError, TypeError
        return [ :saved_questions_invalid ]
      end
      return [ :saved_questions_invalid ] unless validated.size == questions.size

      []
    rescue JSON::ParserError
      [ :saved_questions_invalid ]
    end

    def pdf_reference(attachment)
      blob = attachment&.blob
      return unless blob

      { attachment_id: attachment.id, record_type: attachment.record_type, record_id: attachment.record_id,
        name: attachment.name, blob_id: blob.id, key: blob.key, service_name: blob.service_name,
        byte_size: blob.byte_size, checksum: blob.checksum, content_type: blob.content_type,
        filename: blob.filename.to_s }
    end

    def valid_attachment?(attachment, record_type, record_id, name, pdf)
      attachment.present? && pdf && attachment.record_type == record_type &&
        attachment.record_id == record_id && attachment.name == name && pdf[:blob_id].present?
    end

    def pdf_state(attachment, pdf)
      [ attachment&.id, attachment&.record_type, attachment&.record_id, attachment&.name,
        pdf&.values_at(:blob_id, :key, :service_name, :byte_size, :checksum, :content_type, :filename) ]
    end

    def question_state(question)
      state = question.attributes.slice("id", "assignment_id", "question_label", "position", "question_text",
        "correct_answer", "grading_rule", "answer_generation_model", "answer_generation_prompt_version",
        "answer_generated_at", "updated_at")
      state["answer_generated_at"] = question.answer_generated_at&.iso8601(6)
      state["updated_at"] = question.updated_at&.iso8601(6)
      state
    end

    def inspect_pdf(pdf)
      return result(RESULT_INELIGIBLE, :pdf_metadata_invalid) unless pdf && pdf[:key].present? &&
        pdf[:service_name].present? && pdf[:filename].present? && pdf[:byte_size].to_i.positive? &&
        pdf[:checksum].present? && pdf[:content_type] == "application/pdf"

      blob = ActiveStorage::Blob.find_by(id: pdf[:blob_id])
      return result(RESULT_INELIGIBLE, :pdf_blob_missing) unless blob

      valid = false
      blob.open do |file|
        header = file.read(1024).to_s.include?("%PDF-")
        file.rewind
        mime = Marcel::MimeType.for(file)
        valid = file.size == pdf[:byte_size] && header && mime == "application/pdf"
      end
      return result(RESULT_INELIGIBLE, :pdf_content_invalid) unless valid

      result(RESULT_CANDIDATE, :pdf_verified)
    rescue ActiveStorage::FileNotFoundError
      result(RESULT_INELIGIBLE, :pdf_object_missing)
    rescue ActiveStorage::IntegrityError
      result(RESULT_INELIGIBLE, :pdf_checksum_mismatch)
    rescue StandardError
      result(RESULT_INDETERMINATE, :pdf_storage_unavailable)
    end

    def verify_locked_snapshot(initial, expected_status)
      outcome = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        connection = ActiveRecord::Base.connection
        quoted_key = connection.quote("quickflow-assignment-lifecycle:#{initial.assignment_id}")
        acquired = connection.select_value("SELECT pg_try_advisory_xact_lock(hashtextextended(#{quoted_key}, 0))")

        if !ActiveModel::Type::Boolean.new.cast(acquired)
          outcome = result(RESULT_INDETERMINATE, :assignment_lifecycle_lock_busy)
          next
        end

        assignment = Assignment.lock("FOR NO KEY UPDATE NOWAIT").find_by(id: initial.assignment_id)
        submission = Submission.lock("FOR UPDATE NOWAIT").find_by(id: initial.submission_id)
        if !assignment || !submission
          outcome = result(RESULT_INDETERMINATE, :state_changed)
          next
        end

        Question.where(assignment_id: assignment.id).order(:id).lock("FOR UPDATE NOWAIT").load
        attachments = [ initial.answer_pdf, initial.material_pdf ].map { |pdf| pdf[:attachment_id] }.compact.uniq.sort
        blobs = [ initial.answer_pdf, initial.material_pdf ].map { |pdf| pdf[:blob_id] }.compact.uniq.sort
        ActiveStorage::Attachment.where(id: attachments).order(:id).lock("FOR UPDATE NOWAIT").load
        ActiveStorage::Blob.where(id: blobs).order(:id).lock("FOR SHARE NOWAIT").load
        current = build_snapshot(submission, assignment, expected_status)
        outcome = if current.fingerprint != initial.fingerprint
          result(RESULT_INDETERMINATE, :state_changed)
        elsif current.reason_codes.any?
          result(RESULT_INELIGIBLE, *current.reason_codes)
        else
          yield(submission) || result(RESULT_CANDIDATE, :all_conditions_met_at_observation)
        end
      end
      outcome
    end

    def result(value, *reason_codes)
      { result: value, reason_codes: reason_codes.map(&:to_s) }
    end
  end
end
