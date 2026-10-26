module Recovery
  class RetryToken
    PURPOSE = "teacher-answer-retry-v1"

    def self.issue(submission_id, teacher_id, info)
      verifier.generate(info.slice(:generation, :fingerprint, :status).stringify_keys.merge(
        "submission_id" => submission_id, "teacher_id" => teacher_id), purpose: PURPOSE, expires_in: 15.minutes)
    end

    def self.verify(token, submission_id, teacher_id)
      data = verifier.verified(token, purpose: PURPOSE) if token.is_a?(String) && token.bytesize <= 4096
      return unless data.is_a?(Hash) && data["submission_id"] == submission_id && data["teacher_id"] == teacher_id &&
        data["generation"].is_a?(Integer) && data["generation"] >= 0 &&
        data["fingerprint"].is_a?(String) && data["fingerprint"].match?(/\A[0-9a-f]{64}\z/) &&
        %w[failed grading].include?(data["status"])

      data
    end

    def self.verifier
      Rails.application.message_verifier(PURPOSE)
    end
    private_class_method :verifier
  end
end
