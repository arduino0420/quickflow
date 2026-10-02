class GradingResult < ApplicationRecord
  belongs_to :submission
  belongs_to :question

  enum :reading_confidence, { low: 0, medium: 1, high: 2 }, prefix: true
  enum :ai_judgment, { incorrect: 0, correct: 1, needs_review: 2 }, prefix: true
  enum :teacher_judgment, { incorrect: 0, correct: 1 }, prefix: true

  validates :ai_judgment, :ai_model_name, :prompt_version, :graded_at, presence: true
  validates :question_id, uniqueness: { scope: :submission_id }
end
