class Admin::StudentsController < Admin::BaseController
  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }
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

  def edit
    account = student_account.prepare("edit")
    assign_account(account)
  end

  def confirm_update
    account = student_account
    return reject_identity(account, :edit) if forbidden_account_parameters?

    valid = account.preview(attributes: params.expect(student: [ :grade, :class_number, :attendance_number ]).to_h.symbolize_keys,
      token: params[:edit_token])
    assign_account(account)
    render(valid ? :confirm_update : :edit, status: valid ? :ok : :unprocessable_content)
  end

  def update
    account = student_account
    return reject_identity(account, :edit) if forbidden_account_parameters?

    if params[:confirmed] != "1" || !authenticate_admin_operation(always: true)
      account.student.errors.add(:base, "対象を確認し、管理者自身のパスワードを入力してください。")
      assign_account(account.prepare("edit"))
      return render :edit, status: :unprocessable_content
    end
    saved = account.call(operation: "update", token: params[:edit_token])
    return redirect_to admin_students_path(**@return_filters), notice: "生徒アカウントを更新しました。", status: :see_other if saved

    assign_account(account.prepare("edit"))
    render :edit, status: :unprocessable_content
  end

  def confirm_destroy
    assign_account(student_account.prepare("delete"))
  end

  def destroy
    account = student_account
    return reject_identity(account, :confirm_destroy) if forbidden_account_parameters?

    if params[:confirmed] != "1" || !authenticate_admin_operation(always: true)
      account.student.errors.add(:base, "削除対象を確認し、管理者自身のパスワードを入力してください。")
      assign_account(account.prepare("delete"))
      return render :confirm_destroy, status: :unprocessable_content
    end
    saved = account.call(operation: "delete", token: params[:edit_token])
    return redirect_to admin_students_path(**@return_filters), notice: "確認した生徒1人を削除しました。", status: :see_other if saved

    assign_account(account.prepare("delete"))
    render :confirm_destroy, status: :unprocessable_content
  end

  private

  def student_account
    @return_filters = params.permit(:grade, :class_number, :page).to_h.select { |_, value| value.is_a?(String) && value.match?(/\A[0-9]{1,9}\z/) }
    Admin::StudentAccountChange.new(admin: current_admin, student_id: params[:id])
  end

  def assign_account(account)
    @student = account.student
    @edit_token = account.token
    @changes = account.changes
  end

  def forbidden_account_parameters?
    inputs = [ params, params[:student] ].select { |input| input.respond_to?(:key?) }
    inputs.any? { |input| %w[school_id school_code classroom_id classroom_ids student_id id password password_digest].any? { |key| input.key?(key) && !(input.equal?(params) && key == "id") } }
  end

  def reject_identity(account, template)
    account.student.errors.add(:base, "学校・生徒ID等を直接指定することはできません。")
    assign_account(account.prepare(template == :confirm_destroy ? "delete" : "edit"))
    render template, status: :unprocessable_content
  end

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
