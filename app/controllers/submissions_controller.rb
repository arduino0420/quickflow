class SubmissionsController < ApplicationController
  before_action :require_teacher_login
  before_action :prevent_caching
  before_action :set_submission
  before_action :set_return_context, only: [ :show, :update ]

  def show
    set_grading_results
    if !guest_session? && grading_recovery_enabled? && (@submission.failed? || @submission.grading?)
      @grading_recovery_offer = Recovery::AnswerRecovery.new.offer(@submission, teacher: current_teacher)
    end
  end

  def resume_grading
    unless grading_recovery_enabled? && (@submission.failed? || @submission.grading?)
      return redirect_to assignment_submission_path(@assignment, @submission),
        alert: "現在は採点を再開できません。運用担当者に確認してください。", status: :see_other
    end

    report = Recovery::AnswerRecovery.new.call(@submission.id, teacher: current_teacher, request_token: params[:retry_request_token])
    if report[:result] == "enqueued"
      redirect_to assignment_submission_path(@assignment, @submission),
        notice: "採点の再依頼を受け付けました。処理中です。", status: :see_other
    else
      redirect_to assignment_submission_path(@assignment, @submission),
        alert: grading_recovery_message(report), status: :see_other
    end
  rescue StandardError => error
    Rails.logger.error("Teacher grading recovery failed: submission_id=#{@submission.id} #{error.class}")
    redirect_to assignment_submission_path(@assignment, @submission),
      alert: "現在は採点を再開できません。運用担当者に確認してください。", status: :see_other
  end

  def update
    if params.key?(:final_judgments)
      update_final_judgments
    else
      input = params[:judgments]
      judgments = input.is_a?(ActionController::Parameters) ? input.each_pair.to_h : nil
      original = params[:original_final_judgments]
      original = original.is_a?(ActionController::Parameters) ? original.each_pair.to_h : nil
      @submission.update_teacher_judgments!(judgments, original)
    end
    redirect_to assignment_submission_path(@assignment, @submission, **@return_context), notice: "判定を保存しました。", status: :see_other
  rescue Submission::InvalidTeacherJudgments => error
    render_update_error(error.message)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved
    render_update_error("判定を保存できませんでした。変更は反映されていません。選択し直してください。")
  end

  def answer
    file = @submission.answer_file
    return head :not_found unless file.attached?

    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    disposition = params[:download] == "1" || file.content_type != "application/pdf" ? :attachment : :inline
    send_data file.download, filename: file.filename.to_s,
      type: file.content_type || "application/octet-stream", disposition: disposition
  rescue ActiveStorage::FileNotFoundError
    head :not_found
  end

  private

  def prevent_caching
    response.headers["Cache-Control"] = "private, no-store"
  end

  def update_final_judgments
    input = params[:final_judgments]
    original = params[:original_final_judgments]
    valid = !params.key?(:judgments) && input.is_a?(ActionController::Parameters) && input.present? &&
      original.is_a?(ActionController::Parameters) && input.keys.sort == original.keys.sort &&
      input.each_pair.all? { |id, value|
        id.match?(/\A[1-9][0-9]*\z/) && [ "", "correct", "incorrect" ].include?(value) &&
          [ "correct", "incorrect", "needs_review" ].include?(original[id])
      }
    raise Submission::InvalidTeacherJudgments, "判定の指定が正しくありません。" unless valid

    @submission.with_lock do
      raise Submission::InvalidTeacherJudgments, "採点が完了した答案だけ修正できます。" unless @submission.completed?

      @submission.checked_teacher_judgment_results!(input.keys, original.each_pair.to_h)

      changes = input.each_pair.to_h.reject { |id, value| value.empty? || value == original[id] }
      @submission.update_teacher_judgments!(changes, original.each_pair.to_h.slice(*changes.keys)) if changes.any?
    end
  end

  def set_return_context
    @return_context = {}
    return unless params.key?(:classroom_id)

    classroom_id = params[:classroom_id]
    unless classroom_id == "all"
      raise ActiveRecord::RecordNotFound unless classroom_id.is_a?(String) && classroom_id.match?(/\A[1-9][0-9]*\z/)

      @assignment.classrooms.where(school_id: current_teacher.school_id).find(classroom_id)
    end
    @return_context[:classroom_id] = classroom_id
    @return_context[:filter] = params[:filter] if [ "all", "needs_review" ].include?(params[:filter])
  end

  def set_grading_results
    results = @assignment.reviewable_grading_results.where(submission: @submission)
    @pending_review_count = results.pending_review.count
    @grading_results = results.joins(:question).includes(:question).order("questions.position")
    @score = @submission.score if @submission.completed?
  end

  helper_method def grading_recovery_enabled?
    ENV["QUICKFLOW_GRADING_RECOVERY_ENABLED"] == "true"
  end

  helper_method def grading_recovery_message(report = @grading_recovery_offer)
    codes = report&.fetch(:reason_codes, []) || []
    codes += [ "recovery_registration_unknown" ] if %w[pending uncertain].include?(@submission.grading_recovery_state)
    return "再依頼の受付状況を確認できません。再送せず運用担当者に確認してください。" if (codes & %w[recovery_registration_unknown enqueue_not_confirmed]).any?
    return "再依頼はこの答案の上限3回に達しています。運用担当者に確認してください。" if codes.include?("recovery_attempt_limit")
    return "画面の情報が古いか状態が変わりました。再読み込みして確認してください。" if (codes & %w[state_changed request_invalid_or_expired status_not_failed]).any?
    return "前の受付から60秒以上あけて、画面を再読み込みしてください。" if codes.include?("recovery_cooldown")

    "現在は採点を再開できません。答案や処理状況を運用担当者に確認してください。"
  end

  def render_update_error(message)
    flash.now[:alert] = message
    @submission.reload
    set_grading_results
    render :show, formats: [ :html ], status: :unprocessable_entity
  end

  def require_teacher_login
    redirect_to login_path, status: :see_other unless current_teacher
  end

  def set_submission
    @assignment = current_teacher.assignments.distributed_to_school(current_teacher.school_id).find(params[:assignment_id])
    @submission = @assignment.reviewable_submissions.find(params[:id])
  end
end
