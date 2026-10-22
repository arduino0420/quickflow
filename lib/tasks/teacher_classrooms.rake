namespace :teacher_classrooms do
  desc "Copy and verify legacy classroom teacher pairs (writes data; run only before association cutover)"
  task backfill: :environment do
    begin
      report = TeacherClassrooms::LegacyBackfill.new.call
    rescue TeacherClassrooms::LegacyBackfill::InconsistentData, TeacherClassrooms::LegacyBackfill::VerificationFailed => error
      abort error.message
    rescue ActiveRecord::StatementInvalid
      abort "DB処理に失敗したためコピーを中止しました。競合・DB構造・接続先を確認してください。"
    end
    puts JSON.pretty_generate(report)
  end
end
