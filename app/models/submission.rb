class Submission < ApplicationRecord
  class InvalidTeacherJudgments < StandardError; end

  belongs_to :assignment
  has_many :grading_results
  belongs_to :student

  has_one_attached :answer_file

  enum :status, { submitted: 0, grading: 1, completed: 2, failed: 3 }

  validates :status, :submitted_at, presence: true
  validates :student_id, uniqueness: { scope: :assignment_id }

  validate :assignment_distributed_to_student_classroom

  def score
    return nil unless persisted? && completed?

    question_ids = assignment.questions.order(:id).pluck(:id)
    return nil if question_ids.empty?

    results = grading_results.order(:question_id).to_a
    return nil unless results.map(&:question_id) == question_ids

    results.count { |result| result.final_judgment == "correct" } * assignment.point_per_question
  end

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

  private

  def assignment_distributed_to_student_classroom
    return unless assignment&.teacher && student&.classroom

    unless assignment.teacher.school == student.classroom.school
      errors.add(:assignment, "は生徒と同じ学校の教師が作成した小テストである必要があります")
    end
    unless assignment.assignment_classrooms.exists?(classroom_id: student.classroom_id)
      errors.add(:assignment, "は生徒の所属クラスに配信されている必要があります")
    end
  end
end
