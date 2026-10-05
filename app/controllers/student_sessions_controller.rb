class StudentSessionsController < ApplicationController
  def new
  end

  def create
    credentials = params.require(:student_session).permit(
      :school_code, :grade, :class_number, :attendance_number, :password
    )
    school = School.find_by(school_code: credentials[:school_code])
    classroom = school&.classrooms&.find_by(grade: credentials[:grade], class_number: credentials[:class_number])
    student = classroom&.students&.find_by(attendance_number: credentials[:attendance_number])

    if student&.authenticate(credentials[:password])
      reset_session
      session[:student_id] = student.id
      redirect_to student_login_path, status: :see_other
    else
      flash.now[:alert] = "ログイン情報またはパスワードが正しくありません。"
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to student_login_path, status: :see_other
  end
end
