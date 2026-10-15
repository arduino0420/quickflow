class Admin::TeacherRegistration
  CLASSROOM_CODES = (1..3).flat_map { |grade| (1..10).map { |number| "#{grade}-#{number}" } }.freeze

  attr_reader :teacher, :classroom_codes

  def initialize(admin:)
    @school = admin.school
  end

  def call(attributes:, classroom_codes: nil)
    @teacher = @school.teachers.build(attributes.slice(:user_id, :password, :password_confirmation))
    @teacher.valid?
    if attributes[:password_confirmation].blank?
      @teacher.errors.add(:password_confirmation, :blank)
    end
    validate_classroom_codes(classroom_codes)
    return false if @teacher.errors.any?

    # All registration writes share one transaction. The school row serializes
    # registrations reusing or creating the same classroom in this school.
    @school.with_lock(requires_new: true) do
      @teacher.save!
      @classroom_codes.each do |code|
        grade, number = code.split("-").map(&:to_i)
        classroom = @school.classrooms.find_by(grade: grade, class_number: number) ||
          @school.classrooms.create!(grade: grade, class_number: number)
        @teacher.teacher_classrooms.create!(classroom: classroom)
      end
    end
    true
  rescue ActiveRecord::RecordInvalid => error
    @teacher.errors.add(:base, "教師と担当クラスを保存できませんでした。変更は反映されていません。") unless error.record.equal?(@teacher)
    false
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotSaved,
      ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    @teacher.errors.add(:base, "保存が競合したか処理に失敗しました。変更は反映されていません。もう一度登録してください。")
    false
  end

  private

  def validate_classroom_codes(input)
    input = [] if input.nil?
    valid_shape = input.is_a?(Array) && input.all? { |code| code.is_a?(String) }
    @classroom_codes = valid_shape ? input.reject(&:empty?).uniq & CLASSROOM_CODES : []
    unless valid_shape && (input.reject(&:empty?) - CLASSROOM_CODES).empty?
      @teacher.errors.add(:base, "担当クラスは1〜3年・1〜10組から選択してください。")
    end
  end
end
