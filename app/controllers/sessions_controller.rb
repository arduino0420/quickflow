class SessionsController < ApplicationController
  def new
  end

  def create
    credentials = params.require(:session).permit(:user_id, :password)
    teacher = Teacher.find_by(user_id: credentials[:user_id])

    if teacher&.authenticate(credentials[:password])
      reset_session
      session[:teacher_id] = teacher.id
      redirect_to login_path, status: :see_other
    else
      flash.now[:alert] = "ユーザーIDまたはパスワードが正しくありません。"
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    reset_session
    redirect_to login_path, status: :see_other
  end
end
