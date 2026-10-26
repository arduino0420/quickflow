module Recovery
  # This opt-in policy never broadens the read-only inspector or legacy CLI policy.
  class RetryEligibility < GradingEligibility
    def initialize(teacher:)
      @teacher_id = teacher.id
      @school_id = teacher.school_id
    end

    def call(submission, expected_status: :failed)
      super do |row|
        snapshot = build_snapshot(row, row.assignment, expected_status)
        info = { result: "candidate", reason_codes: [], generation: row.processing_generation,
          fingerprint: snapshot.fingerprint, status: row.status, stage: @missing_reading ? "reading" : "grading" }
        block_given? ? yield(row, info) : info
      end
    end

    private

    def build_snapshot(submission, assignment, expected_status)
      @missing_reading = submission.extracted_text.nil? || submission.extracted_text == ""
      snapshot = super
      known_stage = %w[ready reading grading].include?(submission.processing_claim_stage)
      if @missing_reading
        known_stage &&= submission.failed? && submission.processing_claim_stage == "reading" &&
          submission.processing_claim_token.present? && submission.processing_claimed_at.present?
      end
      snapshot.reason_codes << :processing_origin_unknown unless known_stage
      classroom = submission.student.classroom
      unless assignment.teacher_id == @teacher_id && assignment.teacher.school_id == @school_id &&
          classroom.school_id == @school_id && assignment.assignment_classrooms.exists?(classroom_id: classroom.id)
        snapshot.reason_codes << :teacher_scope_changed
      end
      request = assignment.current_question_generation_request
      if request
        unless request.state == "succeeded" && request.selected_input?(assignment)
          snapshot.reason_codes << :question_generation_not_ready
        end
      elsif @missing_reading
        snapshot.reason_codes << :question_generation_origin_unknown
      end
      snapshot.reason_codes << :recovery_attempt_limit if submission.grading_recovery_attempts >= AnswerRecovery::MAX_ATTEMPTS
      if submission.grading_recovery_requested_at && submission.grading_recovery_requested_at > AnswerRecovery::INTERVAL.ago
        snapshot.reason_codes << :recovery_cooldown
      end
      if %w[pending uncertain].include?(submission.grading_recovery_state)
        snapshot.reason_codes << :recovery_registration_unknown
      end
      if submission.grading_recovery_attempts.negative? ||
          ![ nil, "pending", "enqueued", "uncertain", "started" ].include?(submission.grading_recovery_state) ||
          (submission.grading_recovery_attempts.zero? && (submission.grading_recovery_requested_at || submission.grading_recovery_state)) ||
          (submission.grading_recovery_attempts.positive? && (!submission.grading_recovery_requested_at || !submission.grading_recovery_state))
        snapshot.reason_codes << :recovery_receipt_invalid
      end
      extra = [ @teacher_id, @school_id, classroom.id, classroom.school_id,
        request&.attributes&.slice("id", "assignment_id", "material_blob_id", "model", "prompt_version", "state", "claim_token"),
        submission.grading_recovery_attempts, submission.grading_recovery_requested_at&.iso8601(6), submission.grading_recovery_state ]
      snapshot.fingerprint = Digest::SHA256.hexdigest(JSON.generate([ snapshot.fingerprint, extra ]))
      snapshot
    end

    def validated_problems(text)
      @missing_reading ? [ nil, [] ] : super
    end

    def reading_labels_match?(questions, problems)
      return true if @missing_reading
      return false unless problems && questions.size == problems.size

      matcher = AnswerLabelMatcher.new(questions, problems)
      matches = questions.map { |question| matcher.match(question) }
      matches.all? && matches.map(&:object_id).uniq.size == questions.size
    end
  end
end
