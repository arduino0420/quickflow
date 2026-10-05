class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :current_teacher
  helper_method :current_student

  private

  def current_teacher
    Teacher.find_by(id: session[:teacher_id])
  end

  def current_student
    Student.find_by(id: session[:student_id])
  end
end
