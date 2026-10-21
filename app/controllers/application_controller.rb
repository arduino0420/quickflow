class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_teacher
  helper_method :current_student

  rescue_from AuthenticationThrottle::Limited, with: :authentication_limited
  rescue_from AuthenticationThrottle::Unavailable, with: :authentication_unavailable

  private

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
