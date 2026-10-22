class Admin::DashboardController < Admin::BaseController
  def show
    @school = current_admin.school
  end
end
