# A fresh snapshot for one list/export. Never reuse preloaded question/result
# associations: a teacher may have corrected them since they were loaded.
class SubmissionScores
  def call(submissions)
    completed = submissions.select { |submission| submission.persisted? && submission.completed? }
    return {} if completed.empty?

    question_ids = Question.where(assignment_id: completed.map(&:assignment_id).uniq)
      .order(:id).pluck(:assignment_id, :id).group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }
    results = GradingResult.where(submission_id: completed.map(&:id))
      .order(:question_id).group_by(&:submission_id)

    completed.to_h do |submission|
      expected = question_ids.fetch(submission.assignment_id, [])
      actual = results.fetch(submission.id, [])
      score = if expected.any? && actual.map(&:question_id) == expected
        actual.count { |result| result.final_judgment == "correct" } * submission.assignment.point_per_question
      end
      [ submission.id, score ]
    end
  end
end
