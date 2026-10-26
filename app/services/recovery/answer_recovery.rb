module Recovery
  class AnswerRecovery
    MAX_ATTEMPTS = 3
    INTERVAL = 60.seconds

    def offer(submission, teacher:)
      return refusal("feature_disabled") unless enabled?
      return refusal("status_ineligible") unless submission.failed? || submission.grading?

      RetryEligibility.new(teacher: teacher).call(submission.id, expected_status: submission.status.to_sym) do |row, info|
        if queue_clear?(row)
          info.merge(request_token: RetryToken.issue(row.id, teacher.id, info))
        else
          refusal("job_present_or_unknown")
        end
      end
    rescue StandardError => error
      log("offer_unavailable", error)
      refusal("verification_unavailable")
    end

    def call(submission_id, teacher:, request_token:)
      return refusal("feature_disabled") unless enabled?
      # A caller-owned transaction could commit later than queue registration.
      return refusal("transaction_open") if ApplicationRecord.connection.transaction_open?

      token = RetryToken.verify(request_token, submission_id, teacher.id)
      return refusal("request_invalid_or_expired") unless token

      generation = admission = stage = nil
      report = RetryEligibility.new(teacher: teacher).call(submission_id, expected_status: token.fetch("status").to_sym) do |row, info|
        if info.values_at(:generation, :fingerprint, :status) != token.values_at("generation", "fingerprint", "status")
          refusal("state_changed")
        elsif !queue_clear?(row)
          refusal("job_present_or_unknown")
        else
          stage = info.fetch(:stage)
          generation = row.processing_generation + 1
          row.update!(**SubmissionProcessingClaim.ready_attributes, processing_generation: generation, status: :grading,
            grading_recovery_attempts: row.grading_recovery_attempts + 1,
            grading_recovery_requested_at: Time.current, grading_recovery_state: "pending")
          admission = SubmissionProcessingClaim.ready_admission(row.assignment.reload, row, stage: stage)
          nil
        end
      end
      return report unless generation && admission && report[:result] == "candidate"

      dispatch(submission_id, generation, stage, admission)
    rescue StandardError => error
      # No automatic dispatch after an uncertain primary commit.
      log("acceptance_unavailable", error)
      refusal("verification_unavailable")
    end

    private

    def enabled?
      ENV["QUICKFLOW_GRADING_RECOVERY_ENABLED"] == "true"
    end

    def queue_clear?(row)
      GradingRecovery.new.send(:queue_clear?, row.id, row.assignment_id)
    end

    def dispatch(id, generation, stage, admission)
      klass = stage == "reading" ? AnswerReadingJob : AnswerGradingJob
      begin
        job = klass.perform_later(Submission.find(id), generation, admission: admission)
        if job
          record_dispatch(id, generation, "enqueued")
          Rails.logger.info("Teacher answer recovery: submission_id=#{id} generation=#{generation} stage=#{stage} result=enqueued")
          { result: "enqueued", reason_codes: [] }
        else
          record_dispatch(id, generation, "uncertain")
          refusal("enqueue_not_confirmed")
        end
      rescue StandardError => error
        begin
          record_dispatch(id, generation, "uncertain")
        rescue StandardError => receipt_error
          log("receipt_unavailable", receipt_error)
        end
        log("enqueue_unconfirmed", error)
        refusal("enqueue_not_confirmed")
      end
    end

    def record_dispatch(id, generation, state)
      initial = Submission.find_by(id: id)
      return unless initial

      Assignment.transaction do
        owner = Assignment.lock("FOR NO KEY UPDATE").find_by(id: initial.assignment_id)
        row = Submission.lock.find_by(id: id) if owner
        if row && row.processing_generation == generation && row.grading_recovery_state == "pending"
          row.update!(grading_recovery_state: state)
        end
      end
    end

    def refusal(code)
      { result: "indeterminate", reason_codes: [ code ] }
    end

    def log(code, error)
      Rails.logger.warn("Teacher answer recovery: result=#{code} error_class=#{error.class}")
    end
  end
end
