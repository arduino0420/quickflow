class Student::AssignmentsController < ApplicationController
  before_action :require_student_login
  before_action :prevent_result_caching
  before_action :set_assignment, only: [ :show, :material, :result ]

  def index
    @assignments = available_assignments.order(created_at: :desc, id: :desc)
    submissions = current_student.submissions.where(assignment: @assignments)
    @submissions_by_assignment_id = submissions.includes(:assignment).index_by(&:assignment_id)
    @scores_by_assignment_id = @submissions_by_assignment_id.values.select(&:completed?).to_h do |submission|
      [ submission.assignment_id, submission.score ]
    end
    @pending_review_counts = GradingResult.pending_review.joins(:submission, :question)
      .where(submission: submissions).where("questions.assignment_id = submissions.assignment_id")
      .group(:submission_id).count
  end

  def show
    @submission = current_student.submissions.find_by(assignment: @assignment) ||
      current_student.submissions.build(assignment: @assignment)
  end

  def result
    @submission = current_student.submissions.find_by(assignment: @assignment)
    return redirect_to student_assignment_path(@assignment), status: :see_other unless @submission&.completed?

    @score = @submission.score
    return if @score.nil?

    @grading_results = @submission.grading_results.where(question: @assignment.questions)
      .joins(:question).includes(:question).order("questions.position").to_a
    @pending_review_count = @grading_results.count { |result| result.final_judgment == "needs_review" }
  end

  def material
    file = @assignment.material_file
    return head :not_found unless file.attached?

    disposition = params[:download] == "1" || file.content_type != "application/pdf" ? :attachment : :inline
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    send_data file.download, filename: file.filename.to_s,
      type: file.content_type || "application/octet-stream", disposition: disposition
  rescue ActiveStorage::FileNotFoundError
    head :not_found
  end

  private

  def prevent_result_caching
    response.headers["Cache-Control"] = "private, no-store"
  end

  def require_student_login
    redirect_to student_login_path, status: :see_other unless current_student
  end

  def available_assignments
    current_student.classroom.assignments
  end

  def set_assignment
    @assignment = available_assignments.find(params[:id])
  end
end
