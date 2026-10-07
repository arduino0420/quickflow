class AnswerReadingJob < ApplicationJob
  queue_as :default

  def perform(submission)
    result = AnswerReader.new.call(submission)
    submission.update!(extracted_text: result)
  end
end