namespace :recovery do
  desc "Inspect one submission without changing data (metadata only)"
  task :inspect, [ :submission_id ] => :environment do |_task, args|
    unless args[:submission_id].to_s.match?(/\A[1-9][0-9]*\z/)
      abort "答案IDは正の整数で指定してください。例: bin/rails 'recovery:inspect[123]'"
    end

    submission = Submission.find_by(id: args[:submission_id])
    abort "指定した答案が見つかりません。" unless submission

    puts JSON.pretty_generate(Recovery::SubmissionInspector.new.call(submission))
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
