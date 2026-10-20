class Admin::StudentPasswordResetsController < Admin::BaseController
  rescue_from ActiveRecord::RecordNotFound, with: -> { head :not_found }
  before_action :set_account

  def edit
    @edit_token = @account.prepare("password").token
  end

  def update
    input = params.expect(student: [ :password, :password_confirmation ])
    forbidden = [ params, params[:student] ].any? do |source|
      (%w[school_id school_code classroom_id classroom_ids password_digest id] + (source.equal?(params) ? [] : %w[student_id attendance_number grade class_number])).any? { |key| source.key?(key) }
    end
    if forbidden || params[:confirmed] != "1"
      @student.errors.add(:base, "対象を確認してください。学校・所属・IDは変更できません。")
    elsif !authenticate_admin_operation
      @student.errors.add(:base, "管理者自身のパスワードで再認証してください。")
    elsif @account.call(operation: "password", token: params[:edit_token], attributes: input.to_h.symbolize_keys)
      return redirect_to admin_students_path(**@return_filters), notice: "生徒ID #{@student.id} のパスワードを再設定しました。", status: :see_other
    end
    @edit_token = @account.prepare("password").token
    render :edit, status: :unprocessable_content
  end

  private

  def set_account
    @school = current_admin.school
    @account = Admin::StudentAccountChange.new(admin: current_admin, student_id: params[:student_id])
    @student = @account.student
    @return_filters = params.permit(:grade, :class_number, :page).to_h.select { |_, value| value.is_a?(String) && value.match?(/\A[0-9]{1,9}\z/) }
  end
end
