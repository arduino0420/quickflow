class StudentSessionsController < ApplicationController
  def new
  end

  def create
    credentials = params.require(:student_session).permit(
      :school_code, :grade, :class_number, :attendance_number, :password
    )
    ranges = { grade: 1..6, class_number: 1..15, attendance_number: 1..40 }
    valid_numbers = ranges.all? do |field, range|
      value = credentials[field]
      value.is_a?(String) && value.match?(/\A[0-9]+\z/) && range.cover?(value.to_i)
    end
    school_code = AuthenticationThrottle.identifier(credentials[:school_code])
    school = School.find_by(school_code: school_code) if valid_numbers
    classroom = school&.classrooms&.find_by(grade: credentials[:grade], class_number: credentials[:class_number])
    student = classroom&.students&.find_by(attendance_number: credentials[:attendance_number])

    identity = [ school_code, *ranges.keys.map { |field| valid_numbers ? credentials[field].to_i.to_s : AuthenticationThrottle.identifier(credentials[field]) } ]
    if authenticate_with_limit(student, role: :student, identity: identity, password: credentials[:password])
      reset_session
      session[:student_id] = student.id
      session[:credential_proof] = CredentialSession.issue(student)
      redirect_to student_assignments_path, status: :see_other
    else
      flash.now[:alert] = "ログイン情報またはパスワードが正しくありません。"
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to(Demo::Profile.identity? ? root_path : student_login_path, status: :see_other)
  end
end
