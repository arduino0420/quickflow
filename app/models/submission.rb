class Submission < ApplicationRecord
  belongs_to :assignment
  has_many :grading_results
  belongs_to :student

  has_one_attached :answer_file

  enum :status, { submitted: 0, grading: 1, completed: 2, failed: 3 }

  validates :status, :submitted_at, presence: true
  validates :student_id, uniqueness: { scope: :assignment_id }
end
