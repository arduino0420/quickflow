class Admin::StudentsController < Admin::BaseController
  before_action :set_school

  def index
    @grade = listing_number(:grade, 1..6)
    @class_number = listing_number(:class_number, 1..15)
    requested_page = listing_number(:page, 1..999_999_999) || 1
    @classrooms = @school.classrooms.order(:grade, :class_number).to_a
    students = Student.joins(:classroom).where(classrooms: { school_id: @school.id })
    students = students.where(classrooms: { grade: @grade }) if @grade
    students = students.where(classrooms: { class_number: @class_number }) if @class_number
    @total_count = students.count
    @page_count = [ (@total_count + 39) / 40, 1 ].max
    @page = [ requested_page, @page_count ].min
    @students = students.select(:id, :classroom_id, :attendance_number)
      .order("classrooms.grade", "classrooms.class_number", "students.attendance_number", "students.id")
      .preload(:classroom).limit(40).offset((@page - 1) * 40)
  rescue ArgumentError
    render plain: "絞り込み条件またはページ番号が不正です。", status: :bad_request
  end

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

  def listing_number(key, range)
    value = params[key]
    return if value.nil? || value == ""

    raise ArgumentError unless value.is_a?(String) && value.match?(/\A[0-9]{1,9}\z/) && range.cover?(value.to_i)

    value.to_i
  end

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
