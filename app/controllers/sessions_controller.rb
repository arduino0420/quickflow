class SessionsController < ApplicationController
  def new
  end

  def create
    credentials = params.require(:session).permit(:user_id, :password)
    identity = AuthenticationThrottle.identifier(credentials[:user_id])
    teacher = Teacher.find_by(user_id: identity)

    if authenticate_with_limit(teacher, role: :teacher, identity: identity, password: credentials[:password])
      reset_session
      session[:teacher_id] = teacher.id
      session[:credential_proof] = CredentialSession.issue(teacher)
      redirect_to assignments_path, status: :see_other
    else
      flash.now[:alert] = "ユーザーIDまたはパスワードが正しくありません。"
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to(Demo::Profile.identity? ? root_path : login_path, status: :see_other)
  end
end
