class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_teacher
  helper_method :current_student

  rescue_from AuthenticationThrottle::Limited, with: :authentication_limited
  rescue_from AuthenticationThrottle::Unavailable, with: :authentication_unavailable

  helper_method :guest_session?
  before_action :guard_guest_session
  prepend_around_action :with_guest_read_snapshot

  private

  def with_guest_read_snapshot
    return yield unless guest_session? && request.get? && Demo::Guest.enabled?

    # Keep the manifest check and controller scopes on one PostgreSQL snapshot.
    # RSpec's surrounding fixture transaction already supplies this boundary.
    options = ApplicationRecord.connection.transaction_open? ? {} : { isolation: :repeatable_read }
    ApplicationRecord.transaction(**options) { yield }
  end

  def guest_session?
    session[:guest_role].present? || session[:guest_nonce].present?
  end

  def guard_guest_session
    return unless guest_session?
    response.headers["Cache-Control"] = "private, no-store"
    Demo::Guest.verify!
    if request.delete? && %w[sessions student_sessions admin/sessions].include?(controller_path) && action_name == "destroy"
      Demo::Guest.revoke(session)
      return
    end
    unless Demo::Guest.valid?(session)
      Demo::Guest.revoke(session)
      reset_session
      return head :unauthorized
    end
    return if controller_path == "guest_sessions" && action_name == "create" && request.post?
    allowed = Demo::Guest::READS.fetch(session[:guest_role]).fetch(controller_path, [])
    head :forbidden unless request.get? && allowed.include?(action_name)
  rescue Demo::Guest::Unavailable, ActiveRecord::RecordNotFound
    # Never write authentication state to an unverified/unavailable database.
    reset_session
    head :service_unavailable
  end

  def current_teacher
    return @current_teacher if defined?(@current_teacher)

    record = Teacher.find_by(id: session[:teacher_id])
    @current_teacher = CredentialSession.valid?(record, session[:credential_proof]) ? record : nil
  end

  def current_student
    return @current_student if defined?(@current_student)

    record = Student.find_by(id: session[:student_id])
    @current_student = CredentialSession.valid?(record, session[:credential_proof]) ? record : nil
  end

  def authenticate_with_limit(record, role:, identity:, password:, purpose: :login)
    # REMOTE_ADDR is the actual peer, not a client-controlled Forwarded header.
    # Behind a proxy this may be shared; account keys still isolate classmates.
    AuthenticationThrottle.new(record: record, role: role, identity: identity,
      source: request.get_header("REMOTE_ADDR").to_s, purpose: purpose).authenticate(password)
  end

  def authentication_limited(error)
    response.headers["Retry-After"] = error.retry_after.to_s
    response.headers["Cache-Control"] = "private, no-store"
    render plain: "認証の試行回数が上限に達しました。時間をおいて、もう一度お試しください。", status: :too_many_requests
  end

  def authentication_unavailable
    response.headers["Cache-Control"] = "private, no-store"
    render plain: "現在認証を確認できません。時間をおいて、もう一度お試しください。", status: :service_unavailable
  end
end
