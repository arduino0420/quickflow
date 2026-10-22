class PasswordPolicy
  STUDENT_DIGITS = 8
  TEACHER_MIN_CHARACTERS = 10
  ADMIN_MIN_CHARACTERS = 15
  BCRYPT_MAX_BYTES = 72
  COMMON_FRAGMENTS = %w[password quickflow qwerty 123456789].freeze

  def self.message_for(password, role:)
    return "パスワードを入力してください" unless password.is_a?(String) && password.valid_encoding? && password.present? && !password.include?("\0")

    if role == :student
      return "半角数字8桁を入力してください" unless password.match?(/\A[0-9]{8}\z/)
      return "推測しやすい数字の並びは使用できません" if repeated_pattern?(password) ||
        [ 1, -1 ].any? { |step| password.chars.each_cons(2).all? { |a, b| (a.to_i + step) % 10 == b.to_i } }
    elsif role == :teacher
      return "半角英数字10文字以上で、英字と数字を含めて入力してください" unless password.match?(/\A[A-Za-z0-9]{10,}\z/) &&
        password.match?(/[A-Za-z]/) && password.match?(/[0-9]/)
      return "72バイト以下で入力してください" if password.bytesize > BCRYPT_MAX_BYTES
      normalized = password.downcase
      return "よく使われるパスワードや推測しやすい語句は使用できません" if repeated_pattern?(normalized) ||
        COMMON_FRAGMENTS.any? { |part| normalized.include?(part) }
    else
      return "15文字以上で入力してください" if password.length < ADMIN_MIN_CHARACTERS
      return "72バイト以下で入力してください" if password.bytesize > BCRYPT_MAX_BYTES
      normalized = password.downcase.gsub(/\s+/, "")
      return "よく使われるパスワードや推測しやすい語句は使用できません" if repeated_pattern?(normalized) ||
        COMMON_FRAGMENTS.any? { |part| normalized.include?(part) }
    end
    nil
  end

  def self.repeated_pattern?(password)
    (1..5).any? { |period| password.chars.each_with_index.all? { |char, index| char == password[index % period] } }
  end
  private_class_method :repeated_pattern?
end
