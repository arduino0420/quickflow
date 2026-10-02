class Assignment < ApplicationRecord
  belongs_to :teacher
  has_many :questions
  has_many :assignment_classrooms
  has_many :classrooms, through: :assignment_classrooms

  has_one_attached :material_file

  validates :title, presence: true
  validates :point_per_question, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 }
end
