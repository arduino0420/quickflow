class Assignment < ApplicationRecord
  belongs_to :current_question_generation_request, class_name: "QuestionGenerationRequest", optional: true
  has_many :question_generation_requests
  validate :generation_request_belongs_to_assignment

  belongs_to :teacher
  has_many :answer_drafts
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

  def generation_request_belongs_to_assignment
    if current_question_generation_request && current_question_generation_request.assignment_id != id
      errors.add(:current_question_generation_request, "must belong to this assignment")
    end
  end

  validates :title, presence: true
  validates :point_per_question, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 1 }
end
