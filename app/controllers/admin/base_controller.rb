class Admin::BaseController < ApplicationController
  layout "admin"

  before_action :prevent_caching
  before_action :require_admin_login
  helper_method :current_admin

  private

  def current_admin
    Admin.find_by(id: session[:admin_id])
  end

  def require_admin_login
    redirect_to admin_login_path, status: :see_other unless current_admin
  end

  def prevent_caching
    response.headers["Cache-Control"] = "private, no-store"
  end
end
