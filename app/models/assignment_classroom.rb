class AssignmentClassroom < ApplicationRecord
  belongs_to :assignment
  belongs_to :classroom

  validates :classroom_id, uniqueness: { scope: :assignment_id }
end
