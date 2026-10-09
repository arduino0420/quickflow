class Assignment < ApplicationRecord
  belongs_to :teacher
  has_many :submissions
  has_many :questions
  has_many :assignment_classrooms
  has_many :classrooms, through: :assignment_classrooms

  has_one_attached :material_file

  scope :distributed_to_school, ->(school_id) {
    where(id: AssignmentClassroom.joins(:classroom)
      .where(classrooms: { school_id: school_id }).select(:assignment_id))
  }

  def reviewable_submissions
    submissions.joins(:student).where(students: {
      classroom_id: classrooms.where(school_id: teacher.school_id).select(:id)
    })
  end

  def reviewable_grading_results
    GradingResult.where(submission: reviewable_submissions, question: questions)
  end

  validates :title, presence: true
  validates :point_per_question, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 }
end
