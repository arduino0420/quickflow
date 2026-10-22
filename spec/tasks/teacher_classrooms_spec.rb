require "rails_helper"
require "rake"

RSpec.describe "Legacy teacher classroom backfill task" do
  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("teacher_classrooms:backfill")
    Rake::Task["teacher_classrooms:backfill"].reenable
  end

  it "prints only counts from the verified backfill" do
    report = { legacy_pairs: 2, inserted_pairs: 1, already_present_pairs: 1, total_pairs: 3 }
    backfill = instance_double(TeacherClassrooms::LegacyBackfill, call: report)
    expect(TeacherClassrooms::LegacyBackfill).to receive(:new).and_return(backfill)

    expect { Rake::Task["teacher_classrooms:backfill"].invoke }.to output("#{JSON.pretty_generate(report)}\n").to_stdout
  end

  [ TeacherClassrooms::LegacyBackfill::InconsistentData, TeacherClassrooms::LegacyBackfill::VerificationFailed ].each do |error|
    it "reports #{error} and does not print a success report" do
      allow_any_instance_of(TeacherClassrooms::LegacyBackfill).to receive(:call).and_raise(error, "移行を中止しました")

      expect { expect { Rake::Task["teacher_classrooms:backfill"].invoke }.to raise_error(SystemExit) }
        .to output("移行を中止しました\n").to_stderr
    end
  end

  it "reports SQL failures without exposing raw database details" do
    allow_any_instance_of(TeacherClassrooms::LegacyBackfill).to receive(:call)
      .and_raise(ActiveRecord::StatementInvalid, "private database details")

    expect { expect { Rake::Task["teacher_classrooms:backfill"].invoke }.to raise_error(SystemExit) }
      .to output("DB処理に失敗したためコピーを中止しました。競合・DB構造・接続先を確認してください。\n").to_stderr
  end
end
