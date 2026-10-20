class Admin::BaseController < ApplicationController
  layout "admin"

  before_action :prevent_caching
  before_action :require_admin_login
  helper_method :current_admin, :admin_reauthenticated?

  private

  def current_admin
    Admin.find_by(id: session[:admin_id])
  end

  def require_admin_login
    redirect_to admin_login_path, status: :see_other unless current_admin
  end

  # Stored in Rails' authenticated/encrypted session, bound to this admin and
  # credential revision. A successful operation does not extend the deadline.
  def admin_reauthenticated?
    proof = session[:admin_reauthentication]
    proof.is_a?(Hash) && proof["admin_id"] == current_admin.id && proof["school_id"] == current_admin.school_id &&
      proof["credential"] == Digest::SHA256.hexdigest(current_admin.password_digest) &&
      proof["at"].is_a?(Integer) && proof["at"] <= Time.current.to_i &&
      Time.current.to_i < proof["at"] + 15.minutes.to_i
  end

  def authenticate_admin_operation(always: false)
    password = params[:admin_password]
    return false unless password.nil? || (password.is_a?(String) && password.valid_encoding? && !password.include?("\0"))
    return true if !always && password.blank? && admin_reauthenticated?
    return false unless password.is_a?(String) && password.present? && current_admin.authenticate(password)

    if !always && !admin_reauthenticated?
      session[:admin_reauthentication] = { "admin_id" => current_admin.id, "school_id" => current_admin.school_id,
        "credential" => Digest::SHA256.hexdigest(current_admin.password_digest), "at" => Time.current.to_i }
    end
    true
  end

  def prevent_caching
    response.headers["Cache-Control"] = "private, no-store"
  end
end
