class Classroom < ApplicationRecord
  belongs_to :school
  belongs_to :teacher
  has_many :students

  validates :grade, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 3 }
  validates :class_number, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 },
    uniqueness: { scope: [ :school_id, :grade ] }
end
