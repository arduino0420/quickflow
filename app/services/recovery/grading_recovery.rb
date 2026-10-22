module Recovery
  class GradingRecovery
    # A read-only hint for the teacher page. call performs the full locked check.
    def stopped_grading_candidate?(submission)
      submission.grading? && submission.extracted_text.present? &&
        submission.assignment.questions.exists? && !submission.grading_results.exists? &&
        queue_clear?(submission.id, submission.assignment_id)
    rescue StandardError
      false
    end

    def call(submission_id, interrupted_generation: nil)
      generation = nil
      expected_status = interrupted_generation.nil? ? :failed : :grading
      report = GradingEligibility.new.call(submission_id, expected_status: expected_status) do |submission|
        if interrupted_generation && submission.processing_generation != interrupted_generation
          { result: "indeterminate", reason_codes: [ "generation_changed" ] }
        elsif interrupted_generation && !queue_clear?(submission.id, submission.assignment_id)
          { result: "indeterminate", reason_codes: [ "grading_job_present_or_unknown" ] }
        else
          generation = submission.processing_generation + 1
          submission.update!(processing_generation: generation, status: :grading)
          nil
        end
      end
      return report unless generation && report[:result] == "candidate"

      begin
        raise "Could not enqueue answer grading" unless AnswerGradingJob.perform_later(Submission.find(submission_id), generation)
        { result: "enqueued", reason_codes: [] }
      rescue StandardError => error
        begin
          restore_failed(submission_id, generation)
        rescue StandardError => restore_error
          Rails.logger.error("Grading recovery state restore failed: submission_id=#{submission_id} generation=#{generation} #{restore_error.class}")
        end
        Rails.logger.error("Grading recovery enqueue failed: submission_id=#{submission_id} generation=#{generation} #{error.class}")
        { result: "indeterminate", reason_codes: [ "enqueue_failed" ] }
      end
    end

    private

    def restore_failed(submission_id, generation)
      submission = Submission.find_by(id: submission_id)
      submission&.with_lock do
        if submission.processing_generation == generation && submission.grading? && !submission.grading_results.exists?
          submission.update!(status: :failed)
        end
      end
    end

    # Treat an unreadable or unfamiliar queue entry as active. The second recovery
    # still advances the generation, so a delayed first enqueue cannot write data.
    def queue_clear?(submission_id, assignment_id)
      return false unless ActiveJob::Base.queue_adapter_name.to_s == "solid_queue"

      SolidQueue::Job.where(class_name: %w[AnswerReadingJob AnswerGradingJob QuestionGenerationJob], finished_at: nil).find_each do |job|
        arguments = job.arguments
        values = arguments.is_a?(Hash) && arguments["arguments"]
        reference = values.is_a?(Array) && values.first
        return false unless reference.is_a?(Hash) && reference.keys == [ "_aj_globalid" ]

        global_id = reference.fetch("_aj_globalid")
        expected_type = job.class_name == "QuestionGenerationJob" ? "Assignment" : "Submission"
        return false unless global_id.is_a?(String) && global_id.match?(%r{\Agid://[^/]+/#{expected_type}/[1-9][0-9]*\z})
        target_id = expected_type == "Assignment" ? assignment_id : submission_id
        return false if global_id.split("/").last.to_i == target_id
      end
      true
    rescue StandardError
      false
    end
  end
end
