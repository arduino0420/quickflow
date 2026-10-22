require "io/console"

namespace :accounts do
  desc "Create an admin in an existing school after operator verification (interactive only)"
  task create_admin: :environment do
    abort "対話可能な端末で実行してください。" unless STDIN.tty?
    read_line = ->(prompt) { $stdout.print(prompt); STDIN.gets&.chomp }
    abort "所属確認後に実行してください。" unless read_line.call("管理者本人と学校への所属を確認済みですか？ [y/N]: ") == "y"
    school = School.find_by(school_code: read_line.call("既存の学校コード: "))
    abort "学校が見つかりません。学校はこのタスクでは作成しません。" unless school

    user_id = read_line.call("管理者ユーザーID: ")
    read_password = lambda do |prompt|
      $stdout.print(prompt)
      password = STDIN.noecho { STDIN.gets&.chomp }
      $stdout.puts
      password
    end
    password = read_password.call("パスワード: ")
    confirmation = read_password.call("パスワード（確認）: ")
    abort "パスワード（確認）を入力してください。" if confirmation.blank?
    message = PasswordPolicy.message_for(password, role: :admin)
    abort message if message
    admin = Admin.new(school: school, user_id: user_id, password: password, password_confirmation: confirmation)
    begin
      I18n.with_locale(:ja) do
        abort admin.errors.full_messages.join("\n") unless admin.save
      end
    rescue ActiveRecord::RecordNotUnique
      abort "ユーザーIDはすでに登録されています。"
    end
    $stdout.puts("管理者アカウントを登録しました。ログイン情報は本人に安全に伝えてください。")
  end

  desc "Create a teacher in an existing school after operator verification (interactive only)"
  task create_teacher: :environment do
    abort "対話可能な端末で実行してください。" unless STDIN.tty?
    read_line = ->(prompt) { $stdout.print(prompt); STDIN.gets&.chomp }
    abort "所属確認後に実行してください。" unless read_line.call("教師本人と学校への所属を確認済みですか？ [y/N]: ") == "y"
    school = School.find_by(school_code: read_line.call("既存の学校コード: "))
    abort "学校が見つかりません。学校はこのタスクでは作成しません。" unless school

    user_id = read_line.call("教師ユーザーID: ")
    read_password = lambda do |prompt|
      $stdout.print(prompt)
      password = STDIN.noecho { STDIN.gets&.chomp }
      $stdout.puts
      password
    end
    password = read_password.call("パスワード: ")
    confirmation = read_password.call("パスワード（確認）: ")
    abort "パスワード（確認）を入力してください。" if confirmation.blank?
    message = PasswordPolicy.message_for(password, role: :teacher)
    abort message if message
    teacher = Teacher.new(school: school, user_id: user_id, password: password, password_confirmation: confirmation)
    begin
      I18n.with_locale(:ja) do
        abort teacher.errors.full_messages.join("\n") unless teacher.save
      end
    rescue ActiveRecord::RecordNotUnique
      abort "ユーザーIDはすでに登録されています。"
    end
    $stdout.puts("教師アカウントを登録しました。ログイン情報は本人に安全に伝えてください。")
  end
end
