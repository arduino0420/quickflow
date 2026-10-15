require "rails_helper"
require_relative "../../support/ai_grading_context"

RSpec.describe Recovery::CandidateFinder do
  include_context "AI grading records"

  let(:now) { Time.zone.local(2026, 10, 15, 12) }

  def candidate(number, status:, updated_at:)
    assignment.assignment_classrooms.find_or_create_by!(classroom: classroom)
    owner = Student.create!(classroom: classroom, attendance_number: number, password: "password123")
    Submission.create!(assignment: assignment, student: owner, submitted_at: now,
      status: status, updated_at: updated_at)
  end

  it "includes failed answers of any age and only submitted/grading answers older than the cutoff" do
    recent_failure = candidate(2, status: :failed, updated_at: now)
    old_submitted = candidate(3, status: :submitted, updated_at: now - 31.minutes)
    old_grading = candidate(4, status: :grading, updated_at: now - 32.minutes)
    candidate(5, status: :completed, updated_at: now - 2.hours)
    candidate(6, status: :submitted, updated_at: now - 30.minutes)
    candidate(7, status: :grading, updated_at: now - 29.minutes)

    report = described_class.new.call(observed_at: now)
    expect(report[:submissions].map { |item| item[:submission_id] }).to eq([ old_grading.id, old_submitted.id, recent_failure.id ])
    expect(report[:submissions].first[:selection_reason]).to include("停止とは未確定")
    expect(report[:submissions].last[:selection_reason]).to eq("採点失敗")
    expect(report[:submissions].map { |item| item[:observed_at] }.uniq).to eq([ now.iso8601 ])
  end

  it "orders ties by ID and applies the requested limit" do
    first = candidate(2, status: :failed, updated_at: now)
    candidate(3, status: :failed, updated_at: now)
    report = described_class.new.call(minutes: "10", limit: "1", observed_at: now)
    expect(report[:submissions].map { |item| item[:submission_id] }).to eq([ first.id ])
  end

  it "returns an empty list when no answers match" do
    expect(described_class.new.call(observed_at: now)[:submissions]).to eq([])
  end

  [ 0, -1, "", "abc", "1.5", " 30", "1 OR 1=1" ].each do |invalid|
    it "rejects invalid minutes and limits: #{invalid.inspect}" do
      expect { described_class.new.call(minutes: invalid) }.to raise_error(ArgumentError, /正の整数/)
      expect { described_class.new.call(limit: invalid) }.to raise_error(ArgumentError, /正の整数/)
    end
  end

  it "bounds the number of displayed submissions" do
    expect { described_class.new.call(limit: 1001) }.to raise_error(ArgumentError, /1000件以下/)
  end

  [ 1, described_class::MAX_MINUTES - 1, described_class::MAX_MINUTES ].each do |minutes|
    it "extracts candidates at the cutoff boundary for #{minutes} minutes" do
      cutoff = now - minutes.minutes
      old = candidate(2, status: :grading, updated_at: cutoff - 1.second)
      candidate(3, status: :submitted, updated_at: cutoff)
      candidate(4, status: :grading, updated_at: cutoff + 1.second)

      report = described_class.new.call(minutes: minutes.to_s, observed_at: now)
      expect(report[:cutoff]).to eq(cutoff.iso8601)
      expect(report[:submissions].map { |item| item[:submission_id] }).to eq([ old.id ])
    end
  end

  [ described_class::MAX_MINUTES + 1, (described_class::MAX_MINUTES + 1).to_s, "9" * 40, 10**39 ].each do |invalid|
    it "rejects out-of-range minutes before date calculation or SQL: #{invalid}" do
      expect(now).not_to receive(:-)
      expect(Submission).not_to receive(:where)
      expect { described_class.new.call(minutes: invalid, observed_at: now) }
        .to raise_error(ArgumentError, "経過分数は1〜525600分（365日）で指定してください。")
    end
  end
end
