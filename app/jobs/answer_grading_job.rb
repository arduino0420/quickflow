class AnswerGradingJob < ApplicationJob
  queue_as :default

  def perform(submission)
    submission.reload
    return if submission.completed? || submission.failed?

    AnswerGrader.reading_problems(submission.extracted_text)
    generator = QuestionGenerator.new
    questions = generator.saved_questions(submission.assignment)
    if questions.empty?
      raise "Question generation failed; grading is stopped" if generator.failed?(submission.assignment)

      # The generation job resumes readable submissions after it saves shared questions.
      submission.with_lock { submission.update!(status: :grading) unless submission.completed? || submission.failed? }
      return
    end
    submission.with_lock do
      next if submission.completed? || submission.failed?

      begin
        submission.update!(status: :grading)
        results = AnswerGrader.new.call(submission, questions)
        Submission.transaction(requires_new: true) do
          results.each { |attributes| submission.grading_results.create!(attributes) }
          submission.update!(status: :completed)
        end
      rescue StandardError => error
        submission.reload.update!(status: :failed)
        Rails.logger.error("AnswerGradingJob failed: #{error.class}: #{error.message}")
      end
    end
  rescue StandardError => error
    submission.with_lock { submission.update!(status: :failed) unless submission.completed? || submission.failed? }
    Rails.logger.error("AnswerGradingJob failed: #{error.class}: #{error.message}")
  end
end
