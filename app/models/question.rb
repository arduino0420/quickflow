class Question < ApplicationRecord
  belongs_to :assignment
  has_many :grading_results

  validates :question_label, :question_text, :correct_answer,
    :answer_generation_model, :answer_generation_prompt_version, :answer_generated_at,
    presence: true
  validates :position, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 },
    uniqueness: { scope: :assignment_id }
end
