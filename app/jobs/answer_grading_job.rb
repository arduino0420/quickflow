class AnswerGradingJob < ApplicationJob
  include DiscardDeletedRecord

  queue_as :default

  def perform(submission, generation = 0)
    submission.reload
    return if submission.processing_generation != generation || submission.completed? || submission.failed?

    AnswerGrader.reading_problems(submission.extracted_text)
    generator = QuestionGenerator.new
    questions = generator.saved_questions(submission.assignment)
    if questions.empty?
      raise "Question generation failed; grading is stopped" if generator.failed?(submission.assignment)

      # The generation job resumes readable submissions after it saves shared questions.
      submission.with_lock do
        submission.update!(status: :grading) if submission.processing_generation == generation && !submission.completed? && !submission.failed? && !submission.grading_results.exists?
      end
      return
    end
    submission.with_lock do
      next if submission.processing_generation != generation || submission.completed? || submission.failed? || submission.grading_results.exists?

      begin
        submission.update!(status: :grading)
        results = AnswerGrader.new.call(submission, questions)
        Submission.transaction(requires_new: true) do
          results.each { |attributes| submission.grading_results.create!(attributes) }
          submission.update!(status: :completed)
        end
      rescue StandardError => error
        submission.reload.update!(status: :failed) if submission.processing_generation == generation && !submission.completed? && !submission.failed?
        Rails.logger.error("AnswerGradingJob failed: submission_id=#{submission.id} #{error.class}")
      end
    end
  rescue StandardError => error
    submission.with_lock do
      submission.update!(status: :failed) if submission.processing_generation == generation && !submission.completed? && !submission.failed?
    end
    Rails.logger.error("AnswerGradingJob failed: submission_id=#{submission.id} #{error.class}")
  end
end
