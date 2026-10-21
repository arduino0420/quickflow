# Administrative changes only. Never cascade-delete a student's learning data.
class Admin::StudentAccountChange
  class Conflict < StandardError; end
  attr_reader :student, :token, :changes

  def initialize(admin:, student_id:)
    @admin = admin
    @school = admin.school
    @student = Student.joins(:classroom).where(classrooms: { school_id: @school.id }).find(student_id)
  end

  def prepare(operation)
    messages = @student.errors.full_messages
    @student.reload
    @student.errors.clear
    messages.each { |message| @student.errors.add(:base, message) }
    @token = sign(operation)
    self
  end

  def preview(attributes:, token:)
    safely do
      verify!(token, "edit")
      @changes = { "grade" => number(attributes[:grade], 1..6),
        "class_number" => number(attributes[:class_number], 1..15),
        "attendance_number" => number(attributes[:attendance_number], 1..40) }
      check_changes!
      @token = sign("update", @changes)
    end
  end

  def call(operation:, token:, attributes: {})
    safely(distribution_lock: operation != "password") do
      payload = verify!(token, operation)
      case operation
      when "update"
        @changes = payload.fetch("changes")
        check_changes!
        room = @school.classrooms.find_by(@changes.slice("grade", "class_number"))
        room ||= @school.classrooms.create!(@changes.slice("grade", "class_number"))
        @student.update!(classroom: room, attendance_number: @changes.fetch("attendance_number"))
        advance_revision!
      when "delete"
        raise Conflict, "提出・下書き・配信課題がある生徒は削除できません。" if learning_data? || distributed?([ @student.classroom_id ])

        @student.destroy!
      when "password"
        password = attributes[:password]
        confirmation = attributes[:password_confirmation]
        unless [ password, confirmation ].all? { |value| value.is_a?(String) && value.valid_encoding? && value.present? && !value.include?("\0") }
          raise Conflict, "新しいパスワードと確認入力を入力してください。"
        end
        if (message = PasswordPolicy.message_for(password, role: :student))
          raise Conflict, message
        end
        @student.update!(password: password, password_confirmation: confirmation)
        advance_revision!
      else
        raise Conflict, "操作が不正です。"
      end
    end
  end

  private

  def safely(distribution_lock: false)
    Student.transaction(requires_new: true) do
      # SHARE conflicts with distribution INSERT/DELETE. NOWAIT prevents lock
      # cycles with assignment lifecycle operations; this lock never queues.
      Student.connection.execute("LOCK TABLE assignment_classrooms IN SHARE MODE NOWAIT") if distribution_lock
      @school.lock!("FOR UPDATE NOWAIT")
      @student.lock!("FOR UPDATE NOWAIT")
      @original_revision = @student.updated_at
      room = Classroom.lock("FOR SHARE NOWAIT").find(@student.classroom_id)
      raise ActiveRecord::RecordNotFound unless room.school_id == @school.id

      yield
    end
    true
  rescue Conflict => error
    @student.errors.add(:base, error.message)
    false
  rescue ActiveRecord::RecordInvalid => error
    @student.errors.add(:base, "入力内容を確認してください。保存は完了していません。") unless error.record.equal?(@student)
    false
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::InvalidForeignKey, ActiveRecord::RecordNotSaved,
      ActiveRecord::RecordNotDestroyed, ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout
    @student.errors.add(:base, "他の保存・提出・配信と競合しました。変更せず、画面を開き直してください。")
    false
  end

  def advance_revision!
    @student.touch(time: [ Time.current, @original_revision + 0.001, @student.updated_at + 0.001 ].max)
  end

  def check_changes!
    raise Conflict, "学年・クラス・出席番号の指定が不正です。" unless @changes.values.all?

    room = @school.classrooms.find_by(@changes.slice("grade", "class_number"))
    moved = !room || room.id != @student.classroom_id
    if moved && (learning_data? || distributed?([ @student.classroom_id, room&.id ].compact))
      raise Conflict, "提出・下書きがある場合、または変更前後のクラスに配信課題がある場合は所属を変更できません。"
    end
    if room && room.students.where.not(id: @student.id).exists?(attendance_number: @changes.fetch("attendance_number"))
      raise Conflict, "このクラスの出席番号はすでに使用されています。"
    end
  end

  def learning_data?
    Submission.exists?(student_id: @student.id) || AnswerDraft.exists?(student_id: @student.id)
  end

  def distributed?(ids)
    AssignmentClassroom.where(classroom_id: ids).exists?
  end

  def number(value, range)
    range.find { |candidate| value == candidate.to_s }
  end

  def state
    room = @student.classroom.reload
    Digest::SHA256.hexdigest([ @student.attributes.slice("id", "classroom_id", "attendance_number", "password_digest", "updated_at"),
      room.attributes.slice("id", "school_id", "grade", "class_number") ].to_json)
  end

  def sign(operation, changes = nil)
    verifier.generate({ "admin_id" => @admin.id, "school_id" => @school.id, "student_id" => @student.id,
      "operation" => operation, "state" => state, "changes" => changes }, expires_in: 15.minutes, purpose: "student-account")
  end

  def verify!(token, operation)
    payload = token.is_a?(String) ? verifier.verified(token, purpose: "student-account") : nil
    unless payload.is_a?(Hash) && payload.values_at("admin_id", "school_id", "student_id", "operation", "state") ==
        [ @admin.id, @school.id, @student.id, operation, state ]
      raise Conflict, "確認情報が古いか無効です。一覧から画面を開き直してください。"
    end
    payload
  end

  def verifier
    Rails.application.message_verifier("admin-student-account")
  end
end
