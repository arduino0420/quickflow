class Admin::TeachersController < Admin::BaseController
  before_action :set_school

  def index
    @teachers = @school.teachers.order(:user_id)
    @classrooms_by_teacher = TeacherClassroom.joins(:classroom)
      .where(teacher: @teachers, classrooms: { school_id: @school.id }).includes(:classroom)
      .order("classrooms.grade", "classrooms.class_number").group_by(&:teacher_id)
  end

  def new
    @teacher = @school.teachers.build
    @selected_classroom_codes = []
  end

  def create
    attributes = params.expect(teacher: [ :user_id, :password, :password_confirmation ]).to_h.symbolize_keys
    if forbidden_identity_parameters?
      @teacher = @school.teachers.build(attributes)
      @selected_classroom_codes = []
      @teacher.errors.add(:base, "学校ID・クラスIDを直接指定することはできません。")
      return render :new, status: :unprocessable_entity
    end

    registration = Admin::TeacherRegistration.new(admin: current_admin)
    saved = registration.call(attributes: attributes, classroom_codes: params[:teacher][:classroom_codes])
    @teacher = registration.teacher
    @selected_classroom_codes = registration.classroom_codes
    if saved
      redirect_to admin_teachers_path, notice: "教師アカウントを登録しました。", status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    update = Admin::TeacherUpdate.new(admin: current_admin, teacher_id: params[:id]).prepare
    assign_edit_form(update)
  end

  def update
    attributes = params.expect(teacher: [ :password, :password_confirmation ]).to_h.symbolize_keys
    update = Admin::TeacherUpdate.new(admin: current_admin, teacher_id: params[:id])
    if forbidden_update_parameters?(update.teacher)
      assign_edit_form(update.prepare)
      @teacher.errors.add(:base, "学校・教師ID・クラスIDを変更または直接指定することはできません。")
      return render :edit, status: :unprocessable_entity
    end
    saved = update.call(attributes: attributes, classroom_codes: params[:teacher][:classroom_codes], edit_token: params[:teacher][:edit_token])
    assign_edit_form(update)
    if saved
      redirect_to admin_teachers_path, notice: "教師アカウントを更新しました。", status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def assign_edit_form(update)
    @teacher = update.teacher
    @selected_classroom_codes = update.classroom_codes
    @edit_token = update.edit_token
  end

  def forbidden_update_parameters?(teacher)
    [ params, params[:teacher] ].any? do |input|
      [ :school_id, :teacher_id, :classroom_id, :classroom_ids ].any? { |key| input.key?(key) } ||
        (input.key?(:user_id) && input[:user_id] != teacher.user_id) ||
        (input.key?(:school_code) && input[:school_code] != @school.school_code)
    end || params[:teacher].key?(:id)
  end

  def set_school
    @school = current_admin.school
  end

  def forbidden_identity_parameters?
    [ :school_id, :classroom_id, :classroom_ids ].any? { |key| params.key?(key) || params[:teacher].key?(key) }
  end
end
