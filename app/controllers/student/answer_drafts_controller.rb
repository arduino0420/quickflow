class Student::AnswerDraftsController < ApplicationController
  rescue_from ActionController::InvalidAuthenticityToken, with: :reject_csrf

  before_action :authenticate_student
  before_action :set_assignment
  before_action :check_context

  def show
    draft = AnswerDraft.find_by(student: current_student, assignment: @assignment)
    return conflict("material_changed") if draft && draft.material_fingerprint != AnswerDraftContext.fingerprint(@assignment)

    render json: { draft: serialize(draft), editable: !submitted? }
  end

  def update
    # Bound the raw request before Rails parses potentially large operation arrays.
    return draft_error("request_too_large", :content_too_large) if request.content_length.to_i > AnswerDraft::MAX_BYTES + 16.kilobytes

    data = params[:draft_data]
    return draft_error("invalid_data") unless data.is_a?(ActionController::Parameters) && data.keys.sort == %w[format_version pages] && data[:format_version] == 1 && data[:pages].is_a?(Array)
    version = params[:expected_version]
    return draft_error("invalid_data") unless version.nil? || (version.is_a?(Integer) && version >= 0)

    @assignment.with_lock do
      return conflict("context_changed") unless valid_context?
      return render json: { error: "submitted" }, status: :forbidden if submitted?

      draft = AnswerDraft.find_or_initialize_by(student: current_student, assignment: @assignment)
      return conflict("material_changed") if draft.persisted? && draft.material_fingerprint != AnswerDraftContext.fingerprint(@assignment)
      return conflict("version_conflict") unless (draft.persisted? ? draft.lock_version : nil) == version

      draft.assign_attributes(material_fingerprint: AnswerDraftContext.fingerprint(@assignment),
        format_version: data[:format_version], page_data: data[:pages]&.map { |page| page.respond_to?(:to_unsafe_h) ? page.to_unsafe_h : page })
      draft.save!
      render json: { draft: serialize(draft), editable: true }
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
