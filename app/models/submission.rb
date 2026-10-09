class Submission < ApplicationRecord
  class InvalidTeacherJudgments < StandardError; end

  belongs_to :assignment
  has_many :grading_results
  belongs_to :student

  has_one_attached :answer_file

  enum :status, { submitted: 0, grading: 1, completed: 2, failed: 3 }

  validates :status, :submitted_at, presence: true
  validates :student_id, uniqueness: { scope: :assignment_id }

  def update_teacher_judgments!(judgments)
    unless judgments.is_a?(Hash) && judgments.any? && judgments.all? { |id, value|
        id.is_a?(String) && id.match?(/\A[1-9][0-9]*\z/) && [ nil, "", "correct", "incorrect" ].include?(value)
      }
      raise InvalidTeacherJudgments, "判定の指定が正しくありません。"
    end

    with_lock(requires_new: true) do
      raise InvalidTeacherJudgments, "採点が完了した答案だけ修正できます。" unless completed?

      results = grading_results.where(question: assignment.questions).where(id: judgments.keys).index_by { |result| result.id.to_s }
      raise ActiveRecord::RecordNotFound unless results.keys.sort == judgments.keys.sort

      judgments.each do |id, value|
        results.fetch(id).update!(teacher_judgment: value.presence)
      end
    end
  end
end
