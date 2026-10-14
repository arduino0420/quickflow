module GradingReviewsHelper
  def judgment_label(judgment)
    { "correct" => "正解", "incorrect" => "不正解", "needs_review" => "要確認" }.fetch(judgment, "未設定")
  end

  def submission_status_label(submission)
    return "未提出" unless submission&.persisted?

    { "submitted" => "採点待ち", "grading" => "採点中", "completed" => "採点完了", "failed" => "採点失敗" }.fetch(submission.status)
  end

  def submission_score_label(submission, score, pending_review_count: 0)
    return "—" unless submission&.completed?
    return "得点を表示できません（採点結果を確認してください）" if score.nil?

    pending_review_count.positive? ? "#{score}点（暫定）" : "#{score}点"
  end

  def student_incorrect_feedback(result)
    unless result.ai_judgment == "incorrect"
      return "教師が判定を変更しています。理由は先生に確認してください。"
    end

    explanations = [ result.error_point, result.feedback ].filter_map { |text| text&.strip.presence }.uniq
    explanations.any? ? explanations.join("\n") : "説明は登録されていません。先生に確認してください。"
  end

  def classroom_label(classroom)
    "#{classroom.grade}年#{classroom.class_number}組"
  end
end
