class Student::SubmissionsController < ApplicationController
  before_action :require_student_login

  def create
    @assignment = current_student.classroom.assignments.find(params[:assignment_id])
    return redirect_already_submitted if existing_submission

    @submission = current_student.submissions.build(
      assignment: @assignment, status: :submitted, submitted_at: Time.current
    )
    upload = params.fetch(:submission, ActionController::Parameters.new).permit(:answer_file)[:answer_file]
    return render_errors unless valid_pdf?(upload)

    @submission.answer_file = upload
    Submission.transaction(requires_new: true) { @submission.save! }

    AnswerReadingJob.perform_later(@submission)

    redirect_to student_assignment_path(@assignment), notice: "提出しました", status: :see_other
  rescue ActiveRecord::RecordInvalid
    return redirect_already_submitted if existing_submission

    render_errors
  rescue ActiveRecord::RecordNotUnique
    return redirect_already_submitted if existing_submission

    raise
  end

  private

  def require_student_login
    redirect_to student_login_path, status: :see_other unless current_student
  end

  def existing_submission
    current_student.submissions.find_by(assignment: @assignment)
  end

  def redirect_already_submitted
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
    pdf
  ensure
    upload.tempfile.rewind if upload.is_a?(ActionDispatch::Http::UploadedFile)
  end

  def render_errors
    failed_submission = @submission
    @submission = current_student.submissions.build(assignment: @assignment)
    @submission.errors.copy!(failed_submission.errors)
    render "student/assignments/show", status: :unprocessable_entity
  end
end
