class SubmissionsController < ApplicationController
  before_action :require_teacher_login
  before_action :set_submission

  def show
    set_grading_results
  end

  def update
    input = params[:judgments]
    judgments = input.is_a?(ActionController::Parameters) ? input.each_pair.to_h : nil
    @submission.update_teacher_judgments!(judgments)
    redirect_to assignment_submission_path(@assignment, @submission), notice: "判定を保存しました。", status: :see_other
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

  def set_grading_results
    results = @assignment.reviewable_grading_results.where(submission: @submission)
    @pending_review_count = results.pending_review.count
    @grading_results = results.joins(:question).includes(:question).order("questions.position")
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
