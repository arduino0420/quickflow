class GuestSessionsController < ApplicationController
  def create
    Demo::Guest.verify!
    role = params[:role].to_s
    # Fixed server-side identity bounds cardinality; successful starts consume the budget too.
    authenticate_with_limit(nil, role: :guest, identity: "demo-start", password: nil)
    account = Demo::Guest.record(role)
    Demo::Guest.cleanup_expired!
    Demo::Guest.revoke(session)
    reset_session
    nonce = SecureRandom.hex(32)
    AuthenticationAttemptBucket.create!(key_digest: Demo::Guest.key(nonce), attempts: 0,
      expires_at: Time.current + Demo::Guest::TTL)
    session[:guest_nonce] = nonce
    session[:guest_role] = role
    session[:"#{role}_id"] = account.id
    session[:credential_proof] = CredentialSession.issue(account)
    redirect_to({ "admin" => admin_root_path, "teacher" => assignments_path,
      "student" => student_assignments_path }.fetch(role), status: :see_other)
  rescue Demo::Guest::Unavailable, ActiveRecord::RecordNotFound
    head :not_found
  end
end
