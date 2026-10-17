namespace :recovery do
  desc "Resume grading for one eligible failed submission"
  task :resume_grading, [ :submission_id, :interrupted_generation ] => :environment do |_task, args|
    submission_id = args[:submission_id].to_s
    unless submission_id.match?(/\A[1-9][0-9]*\z/) &&
        submission_id.length <= 19 && submission_id.to_i <= Recovery::GradingEligibility::MAX_SUBMISSION_ID
      abort "答案IDは正の整数で指定してください。"
    end

    generation = args[:interrupted_generation]
    unless generation.nil? || generation.match?(/\A(?:0|[1-9][0-9]*)\z/)
      abort "中断世代は0以上の整数で指定してください。"
    end

    report = Recovery::GradingRecovery.new.call(submission_id.to_i,
      interrupted_generation: generation&.to_i)
    puts JSON.pretty_generate(report)
  end

  desc "Inspect one submission without changing data (metadata only)"
  task :inspect, [ :submission_id ] => :environment do |_task, args|
    unless args[:submission_id].to_s.match?(/\A[1-9][0-9]*\z/)
      abort "答案IDは正の整数で指定してください。例: bin/rails 'recovery:inspect[123]'"
    end

    submission = Submission.find_by(id: args[:submission_id])
    abort "指定した答案が見つかりません。" unless submission

    puts JSON.pretty_generate(Recovery::SubmissionInspector.new.call(submission))
  end

  desc "Check whether one failed submission meets the read-only grading recovery criteria"
  task :eligibility, [ :submission_id ] => :environment do |_task, args|
    submission_id = args[:submission_id].to_s
    unless submission_id.match?(/\A[1-9][0-9]*\z/) &&
        submission_id.length <= 19 && submission_id.to_i <= Recovery::GradingEligibility::MAX_SUBMISSION_ID
      abort "答案IDは正の整数で指定してください。例: bin/rails 'recovery:eligibility[123]'"
    end

    submission = Submission.find_by(id: submission_id.to_i)
    abort "指定した答案が見つかりません。" unless submission

    puts JSON.pretty_generate(Recovery::GradingEligibility.new.call(submission))
  end

  desc "List failed or long-unchanged submissions without changing data (defaults: 30 minutes, 100 rows)"
  task :candidates, [ :minutes, :limit ] => :environment do |_task, args|
    begin
      report = Recovery::CandidateFinder.new.call(minutes: args[:minutes] || 30, limit: args[:limit] || 100)
    rescue ArgumentError => error
      abort error.message
    end
    puts JSON.pretty_generate(report)
  end
end
