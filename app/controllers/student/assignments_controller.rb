class Student::AssignmentsController < ApplicationController
  before_action :require_student_login
  before_action :set_assignment, only: [ :show, :material ]

  def index
    @assignments = available_assignments.order(created_at: :desc, id: :desc)
  end

  def show
    @submission = current_student.submissions.find_by(assignment: @assignment) ||
      current_student.submissions.build(assignment: @assignment)
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
