require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "Student grading presentation", type: :request do
  include_context "AI grading records"

  def login
    post student_login_path, params: { student_session: { school_code: school.school_code,
      grade: classroom.grade, class_number: classroom.class_number,
      attendance_number: student.attendance_number, password: "password123" } }
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def add_result(position:, judgment: :correct, teacher_judgment: nil)
    question = create_question(position: position, label: position.to_s)
    submission.grading_results.create!(question: question, ai_judgment: judgment, teacher_judgment: teacher_judgment,
      student_answer: "本人の回答", error_point: "計算を見直しましょう", feedback: "符号を確認しましょう",
      review_reason: judgment == :needs_review ? "判読が難しい" : nil,
      ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
  end

  [ :submitted, :grading ].each do |state|
    it "shows calm #{state} guidance with no technical interval or invented progress and leaves the PDF outside the frame" do
      submission.update!(status: state)
      submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nanswer"), filename: "answer.pdf", content_type: "application/pdf")
      login
      get student_assignment_path(assignment)
      expect(response).to have_http_status(:ok)
      page = document
      panel = page.at_css(".student-grading-panel")
      frame = panel.at_css("turbo-frame#grading-status")
      expect(panel[:'data-controller']).to eq("grading-presentation")
      expect(panel[:'data-action']).to include("turbo:before-frame-render", "turbo:frame-load", "turbo:fetch-request-error", "turbo:frame-missing")
      expect(frame.at_css("[data-grading-state]")[:'data-grading-state']).to eq(state.to_s)
      expect(frame.at_css("[data-controller='grading-status']")).to be_present
      expect(frame.css("a, button")).to be_empty
      expect(frame.text).not_to include("採点結果を見る", "結果を確認する")
      expect(frame.css(".student-grading-waiting__dot").size).to eq(3)
      expect(frame.at_css(".student-grading-waiting__dots")[:'aria-hidden']).to eq("true")
      expect(frame.text).to include(state == :grading ? "AIが答案を確認しています。" : "採点結果を準備しています。")
      expect(frame.text).not_to include("10秒", "更新します", "%", "％", "問採点済み",
        "時間がかかる場合は、このページを開き直してください。")
      expect(frame.css("[role='progressbar']")).to be_empty
      expect(panel.css("iframe")).to be_empty
      pdf = page.at_css("[data-controller='answer-pdf']")
      expect(pdf[:'data-answer-pdf-url-value']).to eq(answer_student_assignment_path(assignment))
      expect(pdf.parent.parent).to eq(panel.parent)
      expect(document.css("link[rel='stylesheet']").any? { |link| link[:href].include?("student_grading") }).to be(true)
    end
  end

  it "delivers all completed results immediately in question order without server-side hiding or animation" do
    third = add_result(position: 3, judgment: :needs_review)
    first = add_result(position: 1, judgment: :incorrect, teacher_judgment: :correct)
    second = add_result(position: 2, judgment: :incorrect)
    submission.update!(status: :completed)
    login
    get student_assignment_path(assignment)
    cards = document.css("#grading-status [data-grading-presentation-card]")
    expect(cards.map { |card| card[:id] }).to eq([ first, second, third ].map { |result| "question_#{result.question_id}" })
    expect(cards.map { |card| card.at_css(".final-judgment").text }).to eq([ "最終判定：正解", "最終判定：不正解", "最終判定：要確認" ])
    expect(cards.css("[hidden], [aria-hidden='true']")).to be_empty
    cards.each do |card|
      expect(card[:style]).to be_nil
      expect(card[:class]).not_to include("student-result-enter")
    end
    expect(cards[1].text).to include("本人の回答", "計算を見直しましょう", "符号を確認しましょう", second.question.correct_answer)
    expect(cards[2].text).to include("教師による確認が必要です。先生に申告してください。")
    expect(response.body).not_to include("要確認が残るため、現在の得点は暫定です。", "未確認の問題は加点していません。", "必要な場合は先生に申告してください。")
    expect(document.at_css("#student-score").text).to include("5点（暫定）")
    expect(document.css(".student-grading-waiting, [data-controller='grading-status']")).to be_empty
  end

  it "shows 0 points and teacher corrections using the existing final judgment and feedback rules" do
    result = add_result(position: 1, judgment: :correct, teacher_judgment: :incorrect)
    submission.update!(status: :completed)
    login
    get student_assignment_path(assignment)
    expect(document.at_css("#student-score").text).to eq("現在の点数：0点")
    expect(document.at_css(".final-judgment").text).to eq("最終判定：不正解")
    expect(response.body).to include("教師が判定を変更しています。理由は先生に確認してください。")
    expect(result.reload.teacher_judgment).to eq("incorrect")
    expect(document.css(".student-result-enter")).to be_empty
  end

  it "removes waiting decorations after failure and never renders partial result cards" do
    add_result(position: 1)
    submission.update!(status: :failed)
    login
    get student_assignment_path(assignment), headers: { "Turbo-Frame" => "grading-status" }
    expect(document.at_css("[data-grading-state]")[:'data-grading-state']).to eq("failed")
    expect(document.at_css("#grading-status").text).to include("採点に失敗しました。先生に確認してください。")
    expect(document.css(".student-grading-waiting, [data-grading-presentation-card], [data-controller='grading-status']")).to be_empty
  end

  it "does not expose even saved partial results while grading" do
    add_result(position: 1, judgment: :incorrect)
    submission.update!(status: :grading)
    login
    get student_assignment_path(assignment)
    expect(document.css("[data-grading-presentation-card]")).to be_empty
    expect(response.body).not_to include("本人の回答", "計算を見直しましょう")
    expect(document.at_css("#student-score").text).to eq("現在の点数：—")
  end

  it "shows the existing data-integrity alert rather than hiding incomplete completed results" do
    submission.update!(status: :completed)
    login
    get student_assignment_path(assignment)
    expect(response.body).to include("採点結果を表示できません。先生に確認してください")
    expect(document.css("[data-grading-presentation-card], .student-grading-waiting")).to be_empty
    expect(document.at_css("#student-score").text).to eq("現在の点数：—")
  end
end
