require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "Final judgment form", type: :request do
  include_context "AI grading records"

  before do
    assignment.assignment_classrooms.create!(classroom: classroom)
    submission.update!(status: :completed)
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
  end

  def result_for(position, ai: :needs_review, teacher_value: nil)
    question = create_question(position: position, label: "1(#{position})")
    submission.grading_results.create!(question: question, ai_judgment: ai, teacher_judgment: teacher_value,
      ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
  end

  def path
    assignment_submission_path(assignment, submission)
  end

  def form_values
    get path
    document = Nokogiri::HTML(response.body)
    document.css("#teacher-judgments select, #teacher-judgments input[type='hidden']").each_with_object({}) do |field, values|
      match = field[:name]&.match(/\A(final_judgments|original_final_judgments)\[([0-9]+)\]\z/)
      next unless match

      values[match[1]] ||= {}
      values[match[1]][match[2]] = field.name == "select" ? field.at_css("option[selected]")[:value] : field[:value]
    end
  end

  it "shows only final judgments, preselects AI or teacher decisions and leaves review unresolved" do
    results = [ result_for(1, ai: :correct), result_for(2, ai: :incorrect), result_for(3),
      result_for(4, ai: :correct, teacher_value: :incorrect) ]
    values = form_values
    expect(values["final_judgments"].values).to eq([ "correct", "incorrect", "", "incorrect" ])
    expect(values["original_final_judgments"].values).to eq([ "correct", "incorrect", "needs_review", "incorrect" ])
    document = Nokogiri::HTML(response.body)
    expect(document.css("article dt").map(&:text)).not_to include("教師判定", "AI判定")
    expect(document.css("label").map(&:text)).to include("問題1(1)の最終判定")
    expect(document.at_css("#question_#{results[2].question_id}").text).to include("未確定（要確認）")
    expect(document.css("option").map { |option| option[:value] }.uniq).to match_array([ "correct", "incorrect", "" ])
    expect(response.body).not_to include("AIの判定に戻す", "採点状態：採点完了")
  end

  it "preserves all attributes when no problem is changed" do
    results = [ result_for(1, ai: :correct), result_for(2), result_for(3, ai: :incorrect, teacher_value: :correct) ]
    original = results.map(&:attributes)
    patch path, params: form_values
    expect(response).to have_http_status(:see_other)
    expect(results.map { |result| result.reload.attributes }).to eq(original)
  end

  it "ignores an unselected item without clearing an existing teacher decision" do
    result = result_for(1, teacher_value: :correct)
    values = form_values
    original = result.attributes
    values["final_judgments"][result.id.to_s] = ""
    patch path, params: values
    expect(response).to have_http_status(:see_other)
    expect(result.reload.attributes).to eq(original)
  end

  [ "correct", "incorrect" ].each do |judgment|
    it "resolves review as #{judgment}, recalculates the score and leaves other problems untouched" do
      pending = result_for(1)
      untouched = [ result_for(2, ai: :correct), result_for(3, ai: :incorrect, teacher_value: :correct) ]
      original = untouched.map(&:attributes)
      ai_data = pending.attributes.except("teacher_judgment", "updated_at")
      expect(submission.score).to eq(10)
      values = form_values
      values["final_judgments"][pending.id.to_s] = judgment
      patch path, params: values
      expect(response).to have_http_status(:see_other)
      expect(pending.reload.teacher_judgment).to eq(judgment)
      expect(pending.attributes.except("teacher_judgment", "updated_at")).to eq(ai_data)
      expect(untouched.map { |result| result.reload.attributes }).to eq(original)
      expect(submission.reload.score).to eq(judgment == "correct" ? 15 : 10)
      get assignment_path(assignment)
      expect(Nokogiri::HTML(response.body).at_css(".grade-score").text).to eq(judgment == "correct" ? "15点" : "10点")
    end
  end

  it "can change a saved teacher decision from correct to incorrect" do
    result = result_for(1, teacher_value: :correct)
    values = form_values
    values["final_judgments"][result.id.to_s] = "incorrect"
    patch path, params: values
    expect(response).to have_http_status(:see_other)
    expect(result.reload.teacher_judgment).to eq("incorrect")
    expect(submission.reload.score).to eq(0)
  end

  it "does not overwrite a newer teacher correction when an old form's item was untouched" do
    result = result_for(1, ai: :correct)
    values = form_values
    result.update!(teacher_judgment: :incorrect)
    original = result.reload.attributes
    patch path, params: values
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("再読み込み")
    expect(result.reload.attributes).to eq(original)
  end

  it "rejects a stale batch before changing any problem" do
    first = result_for(1)
    second = result_for(2)
    values = form_values
    values["final_judgments"].transform_values! { "incorrect" }
    second.update!(teacher_judgment: :correct)
    original = [ first.reload.attributes, second.reload.attributes ]
    score = submission.reload.score

    patch path, params: values

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include("再読み込み")
    expect([ first.reload.attributes, second.reload.attributes ]).to eq(original)
    expect(submission.reload.score).to eq(score)
  end

  it "checks the current decisions after acquiring the Submission lock" do
    result = result_for(1)
    values = form_values
    values["final_judgments"][result.id.to_s] = "incorrect"
    original = nil
    allow_any_instance_of(Submission).to receive(:with_lock).and_wrap_original do |method, *args, **options, &block|
      result.update!(teacher_judgment: :correct)
      original = result.reload.attributes
      method.call(*args, **options, &block)
    end

    patch path, params: values

    expect(response).to have_http_status(:unprocessable_content)
    expect(result.reload.attributes).to eq(original)
  end

  [ :missing, :stale ].each do |condition|
    it "rejects #{condition} originals through the legacy API, including clearing" do
      first = result_for(1, teacher_value: :correct)
      second = result_for(2, teacher_value: :correct)
      original = [ first.attributes, second.attributes ]
      values = { judgments: { first.id.to_s => "incorrect", second.id.to_s => "" } }
      if condition == :stale
        values[:original_final_judgments] = { first.id.to_s => "correct", second.id.to_s => "incorrect" }
      end
      patch path, params: values
      expect(response).to have_http_status(:unprocessable_content)
      expect([ first.reload.attributes, second.reload.attributes ]).to eq(original)
    end
  end

  it "still clears a teacher judgment through the legacy API with matching originals" do
    result = result_for(1, ai: :incorrect, teacher_value: :correct)
    patch path, params: { judgments: { result.id.to_s => "" }, original_final_judgments: { result.id.to_s => "correct" } }
    expect(response).to have_http_status(:see_other)
    expect(result.reload.teacher_judgment).to be_nil
    expect(result.final_judgment).to eq("incorrect")
  end

  [ "needs_review", "invalid", nil, [], { value: "correct" } ].each do |invalid|
    it "rejects an invalid batch value #{invalid.inspect} before updating any problem" do
      first = result_for(1)
      second = result_for(2)
      values = form_values
      original = [ first.attributes, second.attributes ]
      values["final_judgments"] = { first.id.to_s => "correct", second.id.to_s => invalid }
      patch path, params: values, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect([ first.reload.attributes, second.reload.attributes ]).to eq(original)
    end
  end

  it "rejects a foreign result ID even when its value would otherwise be ignored" do
    first = result_for(1)
    values = form_values
    original = first.attributes
    values["final_judgments"][first.id.to_s] = "correct"
    values["final_judgments"]["999999999"] = ""
    values["original_final_judgments"]["999999999"] = "needs_review"
    patch path, params: values
    expect(response).to have_http_status(:not_found)
    expect(first.reload.attributes).to eq(original)
  end

  it "rolls back the whole batch if saving its second decision fails" do
    first = result_for(1)
    second = result_for(2)
    values = form_values
    original = [ first.attributes, second.attributes ]
    values["final_judgments"].transform_values! { "correct" }
    allow_any_instance_of(GradingResult).to receive(:update!).and_wrap_original do |method, *args|
      raise ActiveRecord::RecordNotSaved if method.receiver.id == second.id

      method.call(*args)
    end
    patch path, params: values
    expect(response).to have_http_status(:unprocessable_content)
    expect([ first.reload.attributes, second.reload.attributes ]).to eq(original)
  end

  it "rejects student access to the new form payload" do
    result_for(1)
    values = form_values
    original = submission.grading_results.map(&:attributes)
    post student_login_path, params: { student_session: { school_code: school.school_code,
      grade: classroom.grade, class_number: classroom.class_number, attendance_number: student.attendance_number, password: "password123" } }
    patch path, params: values
    expect(response).to redirect_to(login_path)
    expect(submission.grading_results.reload.map(&:attributes)).to eq(original)
  end
end
