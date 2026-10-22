class Student::SubmissionsController < ApplicationController
  MAX_PDF_BYTES = 25 * 1024 * 1024

  rescue_from ActionController::InvalidAuthenticityToken, with: :reject_handwritten_csrf

  before_action :require_student_login

  def show
    @assignment = current_student.classroom.assignments.find(params[:assignment_id])
    return head :not_found unless @assignment.teacher.school_id == current_student.classroom.school_id
    return head :conflict unless AnswerDraftContext.valid?(request.headers["X-Draft-Context"], current_student, @assignment)

    response.headers["Cache-Control"] = "private, no-store"
    submission = existing_submission
    render json: { submitted: submission.present?, submission_token: submission_token_for(submission),
      location: student_assignment_path(@assignment) }
  end

  def create
    @assignment = current_student.classroom.assignments.find(params[:assignment_id])
    if handwritten?
      return head :not_found unless @assignment.teacher.school_id == current_student.classroom.school_id
      return head :conflict unless AnswerDraftContext.valid?(request.headers["X-Draft-Context"], current_student, @assignment)
      return head :unprocessable_content if params.key?(:submission_token) && !valid_submission_token?
    end
    AssignmentLifecycleLock.synchronize(@assignment.id) do
      return redirect_already_submitted if existing_submission

      @submission = current_student.submissions.build(
        assignment: @assignment, status: :submitted, submitted_at: Time.current
      )
      upload = params.fetch(:submission, ActionController::Parameters.new).permit(:answer_file)[:answer_file]
      return render_too_large if oversized_pdf?(upload)
      return render_errors unless valid_pdf?(upload)

      # Upload before committing the answer: storage failures must not leave a
      # formally submitted record without its PDF. The usual PDF validation above applies.
      return head :conflict if handwritten? && !valid_draft?
      return render_upload_error unless upload_answer_pdf(upload)

      @submission.answer_file = @uploaded_blob
      @assignment.with_lock(handwritten? ? "FOR UPDATE" : "FOR KEY SHARE") do
        return head :conflict if handwritten? && !valid_draft?
        return redirect_already_submitted if existing_submission

        @submission.save!
      end

      unless enqueue_answer_reading
        return submitted_response("答案PDFは保存されましたが、採点処理を開始できませんでした。再提出せず、先生に確認してください。")
      end

      submitted_response
    end
  rescue PdfReadabilityValidator::Unavailable
    message = "PDFの確認処理を利用できません。手書きと下書きは残っています。時間をおいて、もう一度お試しください。"
    if handwritten?
      render json: { error: "pdf_check_unavailable", message: message }, status: :service_unavailable
    else
      @submission.errors.add(:base, "PDFの確認処理を利用できません。時間をおいて、もう一度お試しください。")
      render "student/assignments/show", status: :service_unavailable
    end
  rescue ActiveRecord::RecordInvalid
    return redirect_already_submitted if existing_submission

    render_errors
  rescue ActiveRecord::RecordNotUnique
    return redirect_already_submitted if existing_submission

    raise
  ensure
    cleanup_unattached_upload
  end

  private

  def reject_handwritten_csrf
    raise ActionController::InvalidAuthenticityToken unless handwritten?

    response.headers["Cache-Control"] = "private, no-store"
    render json: { error: "csrf_failed" }, status: :unprocessable_content
  end

  def upload_answer_pdf(upload)
    @uploaded_blob = ActiveStorage::Blob.build_after_unfurling(io: upload.tempfile,
      filename: upload.original_filename, content_type: "application/pdf")
    if handwritten? && params.key?(:submission_token)
      @uploaded_blob.metadata = @uploaded_blob.metadata.merge("handwritten_submission_token" => params[:submission_token])
    end
    @uploaded_blob.save!
    begin
      @uploaded_blob.upload_without_unfurling(upload.tempfile)
      true
    rescue StandardError => error
      Rails.logger.error("Answer PDF upload failed: #{error.class}")
      false
    end
  end

  def cleanup_unattached_upload
    return unless @uploaded_blob&.persisted?

    @uploaded_blob.purge unless @uploaded_blob.attachments.exists?
  rescue StandardError => error
    Rails.logger.error("Answer PDF upload cleanup failed: blob_id=#{@uploaded_blob.id} #{error.class}")
  end

  def render_upload_error
    message = "答案PDFを保存できませんでした。時間をおいて、もう一度提出してください。"
    if handwritten?
      render json: { error: "storage_unavailable", message: message }, status: :service_unavailable
    else
      @submission.errors.add(:base, message)
      render "student/assignments/show", status: :service_unavailable
    end
  end

  def handwritten?
    request.headers["X-Handwritten-Submission"] == "1"
  end

  def valid_draft?
    return false unless AnswerDraftContext.valid?(request.headers["X-Draft-Context"], current_student, @assignment)

    draft = AnswerDraft.find_by(student: current_student, assignment: @assignment)
    version = params[:draft_version]
    if params.key?(:submission_token)
      return false unless params.key?(:draft_version) && (version == "" ||
        (version.is_a?(String) && version.match?(/\A[0-9]+\z/)))

      expected = version == "" ? nil : version.to_i
      return (draft&.lock_version) == expected &&
        (!draft || draft.material_fingerprint == AnswerDraftContext.fingerprint(@assignment))
    end
    draft && version.is_a?(String) && version.match?(/\A[0-9]+\z/) &&
      draft.lock_version == version.to_i && draft.material_fingerprint == AnswerDraftContext.fingerprint(@assignment)
  end

  def valid_submission_token?
    params[:submission_token].is_a?(String) &&
      params[:submission_token].match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
  end

  def submission_token_for(submission)
    submission&.answer_file&.attached? ? submission.answer_file.blob.metadata["handwritten_submission_token"] : nil
  end

  def submitted_response(alert = nil)
    if handwritten?
      alert ? flash[:alert] = alert : flash[:notice] = "提出しました"
      submission = @submission&.persisted? ? @submission : existing_submission
      render json: { submitted: true, submission_token: submission_token_for(submission),
        location: student_assignment_path(@assignment), alert: alert }
    else
      redirect_to student_assignment_path(@assignment),
        **(alert ? { alert: alert } : { notice: "提出しました" }), status: :see_other
    end
  end

  def enqueue_answer_reading
    raise "Could not enqueue answer reading" unless AnswerReadingJob.perform_later(@submission)

    true
  rescue StandardError => error
    @submission.with_lock do
      @submission.update!(status: :failed) unless @submission.completed? || @submission.failed?
    end
    Rails.logger.error("Answer reading enqueue failed: submission_id=#{@submission.id} #{error.class}")
    @submission.completed?
  end

  def require_student_login
    return if current_student

    if handwritten? || request.format.json? || action_name == "show"
      response.headers["Cache-Control"] = "private, no-store"
      head :unauthorized
    else
      redirect_to student_login_path, status: :see_other
    end
  end

  def existing_submission
    current_student.submissions.find_by(assignment: @assignment)
  end

  def redirect_already_submitted
    if handwritten?
      return head :conflict if params.key?(:submission_token) &&
        submission_token_for(existing_submission) != params[:submission_token]

      return submitted_response
    end

    redirect_to student_assignment_path(@assignment), notice: "すでに提出済みです", status: :see_other
  end

  def valid_pdf?(upload)
    unless upload.is_a?(ActionDispatch::Http::UploadedFile)
      @submission.errors.add(:base, "解答PDFを選択してください")
      return false
    end

    upload.tempfile.rewind
    pdf = File.extname(upload.original_filename).downcase == ".pdf" &&
      Marcel::MimeType.for(upload.tempfile) == "application/pdf"
    @submission.errors.add(:base, "PDFファイルを選択してください") unless pdf
    PdfReadabilityValidator.validate!(upload.tempfile) if pdf
    pdf
  rescue PdfReadabilityValidator::InvalidPdf
    @submission.errors.add(:base, "PDFの内容を確認できません。有効なPDFファイルを選択してください")
    false
  ensure
    upload.tempfile.rewind if upload.is_a?(ActionDispatch::Http::UploadedFile)
  end

  def oversized_pdf?(upload)
    upload.is_a?(ActionDispatch::Http::UploadedFile) && upload.size > MAX_PDF_BYTES
  end

  def render_too_large
    @submission.errors.add(:answer_file, "は25MiB以下のPDFを選択してください")
    return render json: { error: "file_too_large" }, status: :content_too_large if handwritten?

    render "student/assignments/show", status: :content_too_large
  end

  def render_errors
    return render json: { error: "invalid_pdf" }, status: :unprocessable_entity if handwritten?

    failed_submission = @submission
    @submission = current_student.submissions.build(assignment: @assignment)
    @submission.errors.copy!(failed_submission.errors)
    render "student/assignments/show", status: :unprocessable_entity
  end
end
