module Recovery
  class CandidateFinder
    MAX_LIMIT = 1000
    MAX_MINUTES = 525_600

    def call(minutes: 30, limit: 100, observed_at: Time.current)
      minutes = positive_integer(minutes, "経過分数")
      raise ArgumentError, "経過分数は1〜#{MAX_MINUTES}分（365日）で指定してください。" if minutes > MAX_MINUTES

      limit = positive_integer(limit, "表示件数")
      raise ArgumentError, "表示件数は#{MAX_LIMIT}件以下で指定してください。" if limit > MAX_LIMIT

      cutoff = observed_at - minutes.minutes
      candidates = Submission.where(status: :failed).or(
        Submission.where(status: [ :submitted, :grading ]).where("updated_at < ?", cutoff)
      ).order(:updated_at, :id).limit(limit)

      {
        observed_at: observed_at.iso8601, cutoff: cutoff.iso8601, limit: limit,
        submissions: candidates.map do |submission|
          SubmissionInspector.new.call(submission, observed_at: observed_at).merge(
            selection_reason: submission.failed? ? "採点失敗" : "長時間未更新（停止とは未確定）"
          )
        end
      }
    end

    private

    def positive_integer(value, label)
      raise ArgumentError, "#{label}は正の整数で指定してください。" unless value.to_s.match?(/\A[1-9][0-9]*\z/)

      value.to_i
    end
  end
end
