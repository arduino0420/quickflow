class Admin::StudentsController < Admin::BaseController
  before_action :set_school

  def new
    @student = Student.new
  end

  def create
    attributes = params.expect(student: [ :grade, :class_number, :attendance_number, :password, :password_confirmation ]).to_h.symbolize_keys
    if forbidden_school_parameters?
      @student = Student.new
      @student.errors.add(:base, "学校・クラスIDを直接指定したり、学校コードを変更したりすることはできません。")
      return render :new, status: :unprocessable_entity
    end

    registration = Admin::StudentRegistration.new(admin: current_admin)
    saved = registration.call(attributes: attributes)
    @student = registration.student
    @grade = registration.grade
    @class_number = registration.class_number
    if saved
      redirect_to new_admin_student_path, notice: "生徒アカウントを登録しました。", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def set_school
    @school = current_admin.school
  end

  def forbidden_school_parameters?
    [ params, params[:student] ].any? do |input|
      [ :school_id, :classroom_id, :classroom_ids ].any? { |key| input.key?(key) } ||
        (input.key?(:school_code) && input[:school_code] != @school.school_code)
    end
  end
end
