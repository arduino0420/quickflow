class TeacherClassroom < ApplicationRecord
  belongs_to :teacher
  belongs_to :classroom

  validates :classroom_id, uniqueness: { scope: :teacher_id }
  validate :teacher_belongs_to_classroom_school

  private

  def teacher_belongs_to_classroom_school
    return unless teacher && classroom

    unless teacher.school == classroom.school
      errors.add(:teacher, "はクラスと同じ学校に所属している必要があります")
    end
  end
end
