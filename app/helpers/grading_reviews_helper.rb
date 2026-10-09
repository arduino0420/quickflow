module GradingReviewsHelper
  def judgment_label(judgment)
    { "correct" => "正解", "incorrect" => "不正解", "needs_review" => "要確認" }.fetch(judgment, "未設定")
  end

  def submission_status_label(submission)
    { "submitted" => "採点待ち", "grading" => "採点中", "completed" => "採点完了", "failed" => "採点失敗" }.fetch(submission.status)
  end

  def classroom_label(classroom)
    "#{classroom.grade}年#{classroom.class_number}組"
  end
end
