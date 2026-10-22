class Student::AnswerDraftsController < ApplicationController
  rescue_from ActionController::InvalidAuthenticityToken, with: :reject_csrf

  before_action :authenticate_student
  before_action :set_assignment
  before_action :check_context

  def show
    draft = AnswerDraft.find_by(student: current_student, assignment: @assignment)
    return conflict("material_changed") if draft && draft.material_fingerprint != AnswerDraftContext.fingerprint(@assignment)

    payload = { draft: serialize(draft), editable: !submitted? }
    payload[:append_supported] = true if acknowledgment?
    render json: payload
  end

  def recovery
    return conflict("context_changed") unless AnswerDraftContext.valid_recovery?(
      request.headers["X-Recovery-Context"], current_student, @assignment)

    draft = AnswerDraft.find_by(student: current_student, assignment: @assignment)
    return conflict("material_changed") if draft && draft.material_fingerprint != AnswerDraftContext.fingerprint(@assignment)
    if submitted?
      submission = current_student.submissions.find_by!(assignment: @assignment)
      token = submission.answer_file.blob.metadata["handwritten_submission_token"] if submission.answer_file.attached?
      return render json: { submitted: true, submission_token: token,
        location: student_assignment_path(@assignment) }
    end

    render json: { submitted: false, draft: serialize(draft), csrf_token: form_authenticity_token }
  end

  def update
    # Bound the raw request before Rails parses potentially large operation arrays.
    return draft_error("request_too_large", :content_too_large) if request.content_length.to_i > AnswerDraft::MAX_BYTES + 16.kilobytes

    return draft_error("invalid_data") if params.key?(:draft_data) == params.key?(:append_data)

    appending = params.key?(:append_data)
    data = params[appending ? :append_data : :draft_data]
    return draft_error("invalid_data") unless data.is_a?(ActionController::Parameters) && data.keys.sort == %w[format_version pages] && data[:format_version] == 1 && data[:pages].is_a?(Array)
    version = params[:expected_version]
    return draft_error("invalid_data") unless version.nil? || (version.is_a?(Integer) && version >= 0)

    @assignment.with_lock do
      return conflict("context_changed") unless valid_context?
      return render json: { error: "submitted" }, status: :forbidden if submitted?

      draft = AnswerDraft.find_or_initialize_by(student: current_student, assignment: @assignment)
      return conflict("material_changed") if draft.persisted? && draft.material_fingerprint != AnswerDraftContext.fingerprint(@assignment)
      return conflict("version_conflict") unless (draft.persisted? ? draft.lock_version : nil) == version

      pages = data[:pages].map { |page| page.respond_to?(:to_unsafe_h) ? page.to_unsafe_h : page }
      if appending
        return draft_error("invalid_data") unless draft.persisted? && valid_append?(pages, draft.page_data)

        pages = draft.page_data.zip(pages).map do |saved, addition|
          saved.merge("operations" => saved.fetch("operations") + addition.fetch("operations"))
        end
      end
      draft.assign_attributes(material_fingerprint: AnswerDraftContext.fingerprint(@assignment),
        format_version: data[:format_version], page_data: pages)
      draft.save!
      # Old clients keep the full response; new clients only need the confirmed version.
      snapshot = acknowledgment? ?
        { version: draft.lock_version, updated_at: draft.updated_at.iso8601(6) } : serialize(draft)
      render json: { draft: snapshot, editable: true }
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::StaleObjectError
    conflict("version_conflict")
  rescue ActiveRecord::RecordInvalid => error
    reason = error.record.errors.details.fetch(:page_data, []).first&.fetch(:error)
    code = { bytes_limit: "draft_bytes_limit", pages_limit: "draft_pages_limit",
      operations_limit: "draft_operations_limit", points_limit: "draft_points_limit" }.fetch(reason, "invalid_data")
    draft_error(code)
  end

  private

  def acknowledgment?
    request.headers["X-Draft-Response"] == "acknowledgment"
  end

  def valid_append?(pages, saved)
    pages.length == saved.length && pages.each_with_index.all? do |page, index|
      page.is_a?(Hash) && page.keys.sort == %w[operations page_number] &&
        page["page_number"].is_a?(Integer) && page["page_number"] == saved[index]["page_number"] &&
        page["operations"].is_a?(Array)
    end
  end

  def draft_error(code, status = :unprocessable_content)
    response.headers["Cache-Control"] = "private, no-store"
    render json: { error: code }, status: status
  end

  def reject_csrf
    draft_error("csrf_failed")
  end

  def authenticate_student
    response.headers["Cache-Control"] = "private, no-store"
    head :unauthorized unless current_student
  end

  def set_assignment
    @assignment = current_student.classroom.assignments.joins(:teacher)
      .where(teachers: { school_id: current_student.classroom.school_id }).find(params[:assignment_id])
  end

  def valid_context?
    AnswerDraftContext.valid?(request.headers["X-Draft-Context"], current_student, @assignment)
  end

  def check_context
    conflict("context_changed") unless valid_context?
  end

  def submitted?
    current_student.submissions.exists?(assignment: @assignment)
  end

  def conflict(code)
    render json: { error: code }, status: :conflict
  end

  def serialize(draft)
    return unless draft

    { format_version: draft.format_version, pages: draft.page_data,
      version: draft.lock_version, updated_at: draft.updated_at.iso8601(6) }
  end
end
