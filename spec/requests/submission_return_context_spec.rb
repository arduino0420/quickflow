require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "Submission return context", type: :request do
  include_context "AI grading records"

  before do
    submission.update!(status: :completed)
    @result = submission.grading_results.create!(question: create_question, ai_judgment: :needs_review,
      ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
  end

  def path(**context)
    assignment_submission_path(assignment, submission, **context)
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def back_link
    document.css("a").find { |a| a.text == "小テスト詳細へ戻る" }[:href]
  end

  [ "all", "needs_review" ].each do |filter|
    it "preserves all-class #{filter} context through a successful save" do
      context = { classroom_id: "all", filter: filter }
      get assignment_path(assignment, **context)
      expect(document.at_css(".grade-row-link")[:href]).to eq(path(**context))
      get path(**context)
      expect(back_link).to eq(assignment_path(assignment, **context))
      expect(document.at_css("#teacher-judgments")[:action]).to eq(path(**context))
      patch path(**context), params: { final_judgments: { @result.id => "correct" }, original_final_judgments: { @result.id => "needs_review" } }
      expect(response).to redirect_to(path(**context))
      follow_redirect!
      expect(back_link).to eq(assignment_path(assignment, **context))
      expect(@result.reload.teacher_judgment).to eq("correct")
    end
  end

  it "keeps a selected class and filter on validation failure without changing grades" do
    context = { classroom_id: classroom.id.to_s, filter: "needs_review" }
    patch path(**context), params: { final_judgments: { @result.id => "invalid" }, original_final_judgments: { @result.id => "needs_review" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(back_link).to eq(assignment_path(assignment, **context))
    expect(document.at_css("#teacher-judgments")[:action]).to eq(path(**context))
    expect(@result.reload.teacher_judgment).to be_nil
  end

  it "retains the existing default without context" do
    get path
    expect(back_link).to eq(assignment_path(assignment, classroom_id: classroom.id))
    expect(document.at_css("#teacher-judgments")[:action]).to eq(path)
  end

  it "ignores arbitrary filter and return URLs" do
    get path(classroom_id: "all", filter: "https://example.com", return_to: "https://example.com")
    expect(back_link).to eq(assignment_path(assignment, classroom_id: "all"))
    expect(document.at_css("#teacher-judgments")[:action]).to eq(path(classroom_id: "all"))
  end

  [ "0", "-1", "1x", "https://example.com", [ "all" ], { id: "all" } ].each do |invalid|
    it "rejects malformed classroom #{invalid.inspect} before saving" do
      patch path, params: { classroom_id: invalid, judgments: { @result.id => "correct" } }
      expect(response).to have_http_status(:not_found)
      expect(@result.reload.teacher_judgment).to be_nil
    end
  end

  it "rejects undistributed and foreign school classroom IDs" do
    other_school = School.create!(school_code: "OTHERCONTEXT")
    [ Classroom.create!(school: school, grade: 2, class_number: 1),
      Classroom.create!(school: other_school, grade: 1, class_number: 1) ].each do |other|
      get path(classroom_id: other.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "does not grant another teacher access using return context" do
    other = Teacher.create!(school: school, user_id: "other-context", password: "password123")
    post login_path, params: { session: { user_id: other.user_id, password: "password123" } }
    get path(classroom_id: "all", filter: "needs_review")
    expect(response).to have_http_status(:not_found)
  end
end
