class Admin::SessionsController < Admin::BaseController
  skip_before_action :require_admin_login, only: [ :new, :create ]

  def new
    redirect_to admin_root_path, status: :see_other if current_admin
  end

  def create
    credentials = params.expect(admin_session: [ :user_id, :password ])
    identity = AuthenticationThrottle.identifier(credentials[:user_id])
    admin = Admin.find_by(user_id: identity)

    if authenticate_with_limit(admin, role: :admin, identity: identity, password: credentials[:password])
      reset_session
      session[:admin_id] = admin.id
      session[:credential_proof] = CredentialSession.issue(admin)
      redirect_to admin_root_path, status: :see_other
    else
      flash.now[:alert] = "管理者IDまたはパスワードが正しくありません。"
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to admin_login_path, status: :see_other
  end
end
