class Admin::StudentRegistration
  attr_reader :student, :grade, :class_number

  def initialize(admin:)
    @school = admin.school
  end

  def call(attributes:)
    @student = Student.new(attributes.slice(:password, :password_confirmation))
    @grade = bounded_integer(attributes[:grade], 1..3)
    @class_number = bounded_integer(attributes[:class_number], 1..10)
    @student.attendance_number = bounded_integer(attributes[:attendance_number], 1..40)
    @student.errors.add(:base, "学年は1〜3年、クラスは1〜10組、出席番号は1〜40番から選択してください。") unless @grade && @class_number && @student.attendance_number
    @student.errors.add(:password_confirmation, :blank) if attributes[:password_confirmation].blank?
    return false if @student.errors.any?

    # Share the registration lock with teacher registration/editing. A savepoint
    # also guarantees rollback when called inside another transaction.
    @school.with_lock(requires_new: true) do
      @student.classroom = @school.classrooms.find_by(grade: @grade, class_number: @class_number) ||
        @school.classrooms.create!(grade: @grade, class_number: @class_number)
      @student.save!
    end
    true
  rescue ActiveRecord::RecordInvalid => error
    @student.errors.add(:base, "生徒とクラスを保存できませんでした。変更は反映されていません。") unless error.record.equal?(@student)
    false
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotSaved,
      ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    @student.errors.add(:base, "登録が競合したか処理に失敗しました。変更は反映されていません。登録済みでないか確認してください。")
    false
  end

  private

  def bounded_integer(value, range)
    # Compare against fixed strings before conversion, including oversized input.
    range.find { |number| value == number.to_s }
  end
end
