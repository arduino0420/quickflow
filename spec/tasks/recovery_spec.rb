require "rails_helper"
require "rake"
require_relative "../support/ai_grading_context"

RSpec.describe "Read-only recovery tasks" do
  include_context "AI grading records"

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("recovery:inspect")
    %w[recovery:inspect recovery:candidates].each { |name| Rake::Task[name].reenable }
  end

  it "inspects the specified answer without exposing content or changing its state" do
    submission.update!(status: :failed)
    original = submission.attributes
    expect { Rake::Task["recovery:inspect"].invoke(submission.id.to_s) }.to output(
      a_string_including('"classification": "追加確認が必要"', '"status": "failed"', '"unchecked"')
    ).to_stdout
    expect(submission.reload.attributes).to eq(original)
  end

  it "lists candidates with defaults" do
    submission.update!(status: :failed)
    expect { Rake::Task["recovery:candidates"].invoke }.to output(
      a_string_including('"limit": 100', '"selection_reason": "採点失敗"')
    ).to_stdout
  end

  it "passes explicit candidate arguments to the finder" do
    finder = instance_double(Recovery::CandidateFinder)
    expect(Recovery::CandidateFinder).to receive(:new).and_return(finder)
    expect(finder).to receive(:call).with(minutes: "60", limit: "20").and_return(submissions: [])
    expect { Rake::Task["recovery:candidates"].invoke("60", "20") }.to output(/"submissions": \[\]/).to_stdout
  end

  [ nil, "0", "-1", "abc", "1.5", "1 OR 1=1" ].each do |invalid|
    it "rejects an invalid answer ID: #{invalid.inspect}" do
      expect(Submission).not_to receive(:find_by)
      expect { expect { Rake::Task["recovery:inspect"].invoke(invalid) }.to raise_error(SystemExit) }
        .to output(/答案IDは正の整数/).to_stderr
    end
  end

  it "reports an unknown ID without dumping a database error" do
    expect { expect { Rake::Task["recovery:inspect"].invoke("9223372036854775807") }.to raise_error(SystemExit) }
      .to output(/指定した答案が見つかりません/).to_stderr
  end

  it "reports invalid candidate arguments" do
    expect { expect { Rake::Task["recovery:candidates"].invoke("0", "10") }.to raise_error(SystemExit) }
      .to output(/経過分数は正の整数/).to_stderr
  end

  [ "525601", "9" * 40 ].each do |invalid|
    it "reports out-of-range minutes as a Japanese input error: #{invalid}" do
      expect(Submission).not_to receive(:where)
      expect { expect { Rake::Task["recovery:candidates"].invoke(invalid, "10") }.to raise_error(SystemExit) }
        .to output("経過分数は1〜525600分（365日）で指定してください。\n").to_stderr
    end
  end
end
