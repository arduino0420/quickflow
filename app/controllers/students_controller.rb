class StudentsController < ApplicationController
  before_action :require_teacher_login
  before_action :set_classrooms

  def new
    @student = Student.new
  end

  def create
    @student = Student.new(params.require(:student).permit(:attendance_number, :password, :password_confirmation))
    classroom_id = params[:student][:classroom_id]
    unless classroom_id.is_a?(String) && classroom_id.match?(/\A[1-9][0-9]*\z/)
      @student.errors.add(:classroom, "を担当クラスから選択してください")
      return render :new, status: :unprocessable_entity
    end

    @student.classroom = @classrooms.find(classroom_id)
    if (message = PasswordPolicy.message_for(@student.password, role: :student))
      @student.errors.add(:password, message)
      return render :new, status: :unprocessable_entity
    end
    if @student.save
      redirect_to new_student_path, notice: "生徒アカウントを登録しました。ログイン情報は本人に安全に伝えてください。", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    @student.errors.add(:attendance_number, :taken)
    render :new, status: :unprocessable_entity
  end

  private

  def require_teacher_login
    redirect_to login_path, status: :see_other unless current_teacher
  end

  def set_classrooms
    @classrooms = current_teacher.classrooms.where(school_id: current_teacher.school_id, grade: 1..6, class_number: 1..15).order(:grade, :class_number)
  end
end
