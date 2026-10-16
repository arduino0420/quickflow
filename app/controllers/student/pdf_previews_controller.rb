class Student::PdfPreviewsController < ApplicationController
  before_action :require_student_login

  def show
    response.headers["Cache-Control"] = "private, no-store"
    @assignment = current_student.classroom.assignments.joins(:teacher)
      .where(teachers: { school_id: current_student.classroom.school_id })
      .find(params[:assignment_id])
    @draft_context = AnswerDraftContext.issue(current_student, @assignment)
  end

  private

  def require_student_login
    redirect_to student_login_path, status: :see_other unless current_student
  end
end
