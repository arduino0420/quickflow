class AssignmentsController < ApplicationController
  before_action :require_teacher_login

  def new
    @assignment = current_teacher.assignments.build
  end

  def create
    @assignment = current_teacher.assignments.build(assignment_params)

    if @assignment.save
      redirect_to new_assignment_path, notice: "小テストを登録しました", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def require_teacher_login
    redirect_to login_path, status: :see_other unless current_teacher
  end

  def assignment_params
    params.require(:assignment).permit(:title, :point_per_question, :material_file)
  end
end
