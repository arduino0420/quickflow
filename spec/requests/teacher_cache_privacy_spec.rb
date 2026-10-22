require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "Teacher private HTML", type: :request do
  include_context "AI grading records"

  it "does not store grade or answer pages and refuses them after logout" do
    submission
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }

    [ assignments_path, assignment_path(assignment), assignment_submission_path(assignment, submission) ].each do |path|
      get path
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("private", "no-store")
      expect(response.body).to include('name="turbo-cache-control" content="no-cache"') if path != assignments_path
    end

    delete logout_path
    get assignment_submission_path(assignment, submission)
    expect(response).to redirect_to(login_path)
    expect(response.body).not_to include("答案詳細")
  end

  it "does not show the original teacher's results after switching accounts" do
    submission
    colleague = Teacher.create!(school: school, user_id: "colleague", password: "password123")
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
    get assignment_path(assignment)
    expect(response).to have_http_status(:ok)
    delete logout_path
    post login_path, params: { session: { user_id: colleague.user_id, password: "password123" } }

    get assignment_submission_path(assignment, submission)
    expect(response).to have_http_status(:not_found)
  end
end
