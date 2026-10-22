class AssignmentClassroom < ApplicationRecord
  belongs_to :assignment
  belongs_to :classroom

  validates :classroom_id, uniqueness: { scope: :assignment_id }

  validate :classroom_belongs_to_assignment_school

  private

  def classroom_belongs_to_assignment_school
    return unless assignment&.teacher && classroom

    unless assignment.teacher.school == classroom.school
      errors.add(:classroom, "は小テストの作成者と同じ学校に所属している必要があります")
    end
  end
end
