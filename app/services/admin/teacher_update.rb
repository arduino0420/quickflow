class Admin::TeacherUpdate
  attr_reader :teacher, :classroom_codes, :edit_token

  def initialize(admin:, teacher_id:)
    @admin = admin
    @school = admin.school
    @teacher = @school.teachers.find(teacher_id)
  end

  def prepare
    @school.with_lock do
      @teacher.lock!
      @classroom_codes = current_classrooms.map { |classroom| code_for(classroom) }
      @edit_token = verifier.generate(token_payload, purpose: :teacher_edit)
    end
    self
  end

  def call(attributes:, classroom_codes:, edit_token:)
    @edit_token = edit_token
    @classroom_codes = []
    @school.with_lock(requires_new: true) do
      @teacher.lock!
      payload = edit_token.is_a?(String) ? verifier.verified(edit_token, purpose: :teacher_edit) : nil
      if payload != token_payload
        @teacher.errors.add(:base, "編集内容が古いか確認情報が無効です。編集画面を開き直してください。")
        return false
      end
      unless current_classrooms.all? { |classroom| classroom.school_id == @school.id && allowed_codes.include?(code_for(classroom)) }
        @teacher.errors.add(:base, "表示範囲外または他校の担当クラスがあるため更新できません。運用担当者へ確認してください。")
        return false
      end
      validate_selection(classroom_codes)
      return false if @teacher.errors.any?

      if attributes[:password].present?
        @teacher.assign_attributes(attributes.slice(:password, :password_confirmation))
        @teacher.valid?
        @teacher.errors.add(:password_confirmation, :blank) if attributes[:password_confirmation].blank?
        return false if @teacher.errors.any?
      end
      @teacher.save!
      selected = @classroom_codes.map do |code|
        grade, number = code.split("-").map(&:to_i)
        @school.classrooms.find_by(grade: grade, class_number: number) ||
          @school.classrooms.create!(grade: grade, class_number: number)
      end
      selected.each do |classroom|
        @teacher.teacher_classrooms.find_by(classroom: classroom) || @teacher.teacher_classrooms.create!(classroom: classroom)
      end
      # Remove relationships only; never destroy classrooms or their data.
      TeacherClassroom.where(teacher: @teacher).where.not(classroom_id: selected.map(&:id)).delete_all
      @teacher.touch(time: [ Time.current, @teacher.updated_at + 0.001 ].max)
    end
    true
  rescue ActiveRecord::RecordInvalid => error
    @teacher.errors.add(:base, "教師と担当クラスを保存できませんでした。変更は反映されていません。") unless error.record.equal?(@teacher)
    false
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotSaved,
      ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    @teacher.errors.add(:base, "保存が競合したか処理に失敗しました。変更は反映されていません。編集画面を開き直してください。")
    false
  end

  private

  def verifier
    Rails.application.message_verifier("admin-teacher-edit")
  end

  def token_payload
    state = [ @teacher.attributes.slice("id", "school_id", "user_id", "password_digest", "updated_at"),
      TeacherClassroom.where(teacher: @teacher).order(:id).pluck(:id, :classroom_id),
      current_classrooms.map { |classroom| [ classroom.id, classroom.school_id, classroom.grade, classroom.class_number ] } ]
    { "admin_id" => @admin.id, "teacher_id" => @teacher.id, "state" => Digest::SHA256.hexdigest(state.to_json) }
  end

  def current_classrooms
    @teacher.classrooms.reorder(:id).to_a
  end

  def allowed_codes
    Admin::TeacherRegistration::CLASSROOM_CODES
  end

  def code_for(classroom)
    "#{classroom.grade}-#{classroom.class_number}"
  end

  def validate_selection(input)
    input = [] if input.nil?
    valid_shape = input.is_a?(Array) && input.all? { |code| code.is_a?(String) }
    @classroom_codes = valid_shape ? input.reject(&:empty?).uniq & allowed_codes : []
    unless valid_shape && (input.reject(&:empty?) - allowed_codes).empty?
      @teacher.errors.add(:base, "担当クラスは1〜3年・1〜10組から選択してください。")
    end
  end
end
