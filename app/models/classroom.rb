class Classroom < ApplicationRecord
  belongs_to :school
  has_many :teacher_classrooms
  has_many :teachers, through: :teacher_classrooms
  has_many :students
  has_many :assignment_classrooms
  has_many :assignments, through: :assignment_classrooms

  validates :grade, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 6 }
  validates :class_number, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 15 },
    uniqueness: { scope: [ :school_id, :grade ] }
end
