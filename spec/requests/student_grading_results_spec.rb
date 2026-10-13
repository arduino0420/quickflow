require "rails_helper"

RSpec.describe "Student grading results", type: :request do
  let(:school) { School.create!(school_code: "RESULTS") }
  let(:teacher) { Teacher.create!(school: school, user_id: "results-teacher", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  let(:assignment) do
    item = Assignment.create!(teacher: teacher, title: "結果を確認する小テスト", point_per_question: 5)
    item.assignment_classrooms.create!(classroom: classroom)
    item
  end
  let(:submission) { Submission.create!(assignment: assignment, student: student, status: :completed, submitted_at: Time.current) }

  def login
    post student_login_path, params: { student_session: {
      school_code: school.school_code, grade: classroom.grade, class_number: classroom.class_number,
      attendance_number: student.attendance_number, password: "password123"
    } }
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def result_path(item = assignment)
    result_student_assignment_path(item)
  end

  def list_row
    document.at_css("#assignment_#{assignment.id}")
  end

  def question_for(position: 1, owner: assignment)
    Question.create!(assignment: owner, position: position, question_label: position.to_s,
      question_text: "1 + 1", correct_answer: "2", answer_generation_model: "test-model",
      answer_generation_prompt_version: "v1", answer_generated_at: Time.current)
  end

  def result_for(item = submission, question: nil, position: 1, judgment: :correct, teacher_judgment: nil, **details)
    question ||= question_for(position: position)
    item.grading_results.create!(question: question, student_answer: "本人の解答", ai_judgment: judgment,
      teacher_judgment: teacher_judgment, ai_model_name: "test-model", prompt_version: "v1",
      graded_at: Time.current, **details)
  end

  { nil => "未提出", submitted: "採点待ち", grading: "採点中", completed: "採点完了", failed: "採点失敗" }.each do |state, label|
    it "shows #{label} with points and a result link only for valid completed grading" do
      assignment
      if state
        result_for
        submission.update!(status: state)
      end
      login
      get student_assignments_path

      expect(list_row.text).to include("採点状態：#{label}")
      if state == :completed
        expect(list_row.text).to include("現在の得点：5点")
        expect(list_row.at_css("a[href='#{result_path}']")).to be_present
      else
        expect(list_row.text).to include("得点：—")
        expect(list_row.text).not_to include("0点")
        expect(list_row.at_css("a[href='#{result_path}']")).to be_nil
      end

      get student_assignment_path(assignment)
      frame = document.at_css("#grading-status")
      if state
        expect(frame.text).to include(label)
        expect(frame.at_css("a[href='#{result_path}']").present?).to eq(state == :completed)
        expect(frame.at_css("[data-controller='grading-status']").present?).to eq([ :submitted, :grading ].include?(state))
      else
        expect(frame).to be_nil
        expect(document.at_css("form")[:action]).to eq(student_assignment_submission_path(assignment))
        expect(student.submissions).to be_empty
      end
    end
  end

  it "shows zero points as a valid completed score and links to the results" do
    result_for(judgment: :incorrect)
    login
    get student_assignments_path
    expect(list_row.text).to include("現在の得点：0点")
    expect(list_row.at_css("a[href='#{result_path}']")).to be_present

    get result_path
    expect(document.at_css("#student-score").text).to eq("現在の得点：0点")
  end

  it "shows 70 points for seven correct answers worth ten points each" do
    assignment.update!(point_per_question: 10)
    10.times { |index| result_for(position: index + 1, judgment: index < 7 ? :correct : :incorrect) }
    login
    get result_path

    expect(document.at_css("#student-score").text).to eq("現在の得点：70点")
  end

  it "shows the person's final judgments in question position order with incorrect explanations" do
    result_for(position: 3)
    result_for(position: 1, judgment: :incorrect, student_answer: "3", error_point: "足し算が違います。", feedback: "計算を確認しましょう。")
    result_for(position: 2, judgment: :needs_review)
    login
    get result_path

    expect(response).to have_http_status(:ok)
    expect(document.at_css("h1").text).to include(assignment.title)
    expect(document.css("article h2").map(&:text)).to eq([ "問題 1", "問題 2", "問題 3" ])
    expect(document.css(".final-judgment").map(&:text)).to eq([ "最終判定：不正解", "最終判定：要確認", "最終判定：正解" ])
    fields = document.css("article").first.css("dt, dd").map(&:text).each_slice(2).to_h
    expect(fields).to eq("生徒解答（AI読み取り結果）" => "3", "正答" => "2",
      "誤り箇所" => "足し算が違います。", "短いフィードバック" => "計算を確認しましょう。")
    expect(response.body).to include("教師による確認が必要です。", "必要な場合は先生に申告してください。")
    expect(document.at_css("#student-score").text).to eq("現在の得点：5点（暫定）")
    expect(response.body).to include("未確認の問題は加点していません。")
    expect(document.css("form, select")).to be_empty
  end

  it "shows provisional zero when every question still needs teacher review" do
    result_for(judgment: :needs_review)
    login
    get student_assignments_path
    expect(list_row.text).to include("0点（暫定）")
    get result_path

    expect(document.at_css("#student-score").text).to eq("現在の得点：0点（暫定）")
    expect(response.body).to include("現在の得点は暫定です。", "未確認の問題は加点していません。")
  end

  it "hides obsolete incorrect explanations after the teacher marks an answer correct" do
    result_for(judgment: :incorrect, teacher_judgment: :correct,
      error_point: "古い誤り箇所", feedback: "古いフィードバック")
    login
    get result_path

    expect(document.at_css(".final-judgment").text).to eq("最終判定：正解")
    expect(document.at_css("#student-score").text).to eq("現在の得点：5点")
    expect(response.body).not_to include("古い誤り箇所", "古いフィードバック")
    expect(document.css("article dl")).to be_empty
  end

  it "does not invent missing explanations when the teacher marks an answer incorrect" do
    result_for(teacher_judgment: :incorrect, student_answer: nil)
    login
    get result_path

    expect(response).to have_http_status(:ok)
    expect(document.at_css(".final-judgment").text).to eq("最終判定：不正解")
    expect(document.at_css("#student-score").text).to eq("現在の得点：0点")
    expect(response.body).to include("読み取り結果がありません。先生に確認してください。", "説明は登録されていません。先生に確認してください。")
  end

  [ :correct, :incorrect, :needs_review ].each do |ai|
    it "shows the latest result after a teacher corrects and restores AI #{ai}" do
      result = result_for(judgment: ai)
      teacher_value = ai == :correct ? "incorrect" : "correct"
      original_score = ai == :correct ? "5点" : (ai == :needs_review ? "0点（暫定）" : "0点")
      corrected_score = ai == :correct ? "0点" : "5点"
      login
      get result_path
      expect(document.at_css("#student-score").text).to eq("現在の得点：#{original_score}")

      post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
      patch assignment_submission_path(assignment, submission), params: { judgments: { result.id.to_s => teacher_value } }
      expect(response).to have_http_status(:see_other)
      login
      get result_path
      expect(document.at_css("#student-score").text).to eq("現在の得点：#{corrected_score}")
      expect(document.at_css(".final-judgment").text).to eq("最終判定：#{teacher_value == 'correct' ? '正解' : '不正解'}")
      get student_assignments_path
      expect(list_row.text).to include("現在の得点：#{corrected_score}")

      post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
      patch assignment_submission_path(assignment, submission), params: { judgments: { result.id.to_s => "" } }
      login
      get result_path
      expect(document.at_css("#student-score").text).to eq("現在の得点：#{original_score}")
      get student_assignments_path
      expect(list_row.text).to include("現在の得点：#{original_score}")
    end
  end

  [ :submitted, :grading, :failed ].each do |state|
    it "does not publish stored results or correct answers while #{state}" do
      result = result_for(judgment: :incorrect, student_answer: "非公開の解答", error_point: "非公開の説明")
      result.question.update!(correct_answer: "非公開の正答")
      submission.update!(status: state)
      login
      get result_path

      expect(response).to redirect_to(student_assignment_path(assignment))
      follow_redirect!
      expect(document.css("article")).to be_empty
      expect(response.body).not_to include("非公開の解答", "非公開の説明", "非公開の正答")
      expect(document.at_css("#grading-status a[href='#{result_path}']")).to be_nil
    end
  end

  [ :no_questions, :missing_result, :foreign_result, :foreign_replacement ].each do |invalid|
    it "does not publish a completed result with #{invalid} as a valid score" do
      if invalid == :no_questions
        submission
      else
        result = result_for(judgment: :incorrect, student_answer: "非公開の解答", feedback: "非公開の説明")
        result.question.update!(correct_answer: "非公開の正答")
        question_for(position: 2) if [ :missing_result, :foreign_replacement ].include?(invalid)
        if [ :foreign_result, :foreign_replacement ].include?(invalid)
          foreign = Assignment.create!(teacher: teacher, title: "別の小テスト", point_per_question: 5)
          foreign.assignment_classrooms.create!(classroom: classroom)
          result_for(question: question_for(owner: foreign), judgment: :needs_review, student_answer: "別小テストの解答")
        end
      end
      login
      get student_assignments_path
      expect(list_row.text).to include("採点完了", "採点結果を表示できません。先生に確認してください")
      expect(list_row.at_css("a[href='#{result_path}']")).to be_nil
      get result_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("採点結果を表示できません。先生に確認してください")
      expect(document.at_css("#student-score")).to be_nil
      expect(document.css("article")).to be_empty
      expect(response.body).not_to include("0点", "非公開の解答", "非公開の説明", "非公開の正答", "別小テストの解答")
    end
  end

  it "uses only the logged-in person's submission even when another person's IDs are supplied" do
    own_result = result_for(judgment: :incorrect, student_answer: "本人だけの解答")
    other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    other_submission = Submission.create!(assignment: assignment, student: other_student, status: :completed, submitted_at: Time.current)
    result_for(other_submission, question: own_result.question, student_answer: "他人だけの解答")
    login
    get student_assignments_path
    expect(list_row.text).to include("0点")
    get result_path, params: { student_id: other_student.id, submission_id: other_submission.id }

    expect(response.body).to include("本人だけの解答")
    expect(response.body).not_to include("他人だけの解答")
    expect(document.at_css("#student-score").text).to eq("現在の得点：0点")
    expect { Rails.application.routes.recognize_path("/student/submissions/#{other_submission.id}", method: :get) }
      .to raise_error(ActionController::RoutingError)
  end

  it "does not borrow a classmate's completed results when the logged-in person has not submitted" do
    other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    other_submission = Submission.create!(assignment: assignment, student: other_student, status: :completed, submitted_at: Time.current)
    result_for(other_submission, judgment: :incorrect, student_answer: "他人だけの解答")
    login
    get student_assignments_path
    expect(list_row.text).to include("未提出", "得点：—")
    get result_path

    expect(response).to redirect_to(student_assignment_path(assignment))
    follow_redirect!
    expect(response.body).not_to include("他人だけの解答")
    expect(student.submissions).to be_empty
  end

  [ :completed, :failed ].each do |state|
    it "removes automatic refreshing when a waiting status changes to #{state}" do
      result_for
      submission.update!(status: :grading)
      login
      get student_assignment_path(assignment), headers: { "Turbo-Frame" => "grading-status" }
      expect(document.at_css("#grading-status [data-controller='grading-status']")).to be_present
      expect(document.at_css("#grading-status a").text).to eq("状態を更新")

      submission.update!(status: state)
      get student_assignment_path(assignment), headers: { "Turbo-Frame" => "grading-status" }
      expect(document.at_css("#grading-status [data-controller='grading-status']")).to be_nil
      if state == :completed
        expect(document.at_css("#grading-status a")[:href]).to eq(result_path)
        expect(document.at_css("#grading-status a")["data-turbo-frame"]).to eq("_top")
      else
        expect(document.at_css("#grading-status").text).to include("採点に失敗しました。先生に確認してください。")
        expect(document.css("#grading-status a")).to be_empty
      end
    end
  end

  it "does not share or snapshot-cache personal status and results" do
    result_for
    login
    [ student_assignments_path, student_assignment_path(assignment), result_path ].each do |path|
      get path
      expect(response.headers["Cache-Control"]).to include("private", "no-store")
      expect(document.at_css("meta[name='turbo-cache-control']")[:content]).to eq("no-cache")
    end
  end

  it "escapes stored titles, question labels, answers and AI explanations" do
    unsafe = '<script>alert("unsafe")</script>'
    assignment.update!(title: unsafe)
    result = result_for(judgment: :incorrect, student_answer: unsafe, error_point: unsafe, feedback: '<img src=x onerror="alert(1)">')
    result.question.update!(question_label: unsafe, correct_answer: unsafe)
    login
    get result_path

    expect(document.css("h1 script, article script, article img")).to be_empty
    expect(document.at_css("article").text).to include(unsafe, '<img src=x onerror="alert(1)">')
    expect(response.body).to include("&lt;script&gt;")
  end

  it "reads existing records without modifying data or starting AI jobs" do
    result = result_for
    records = [ assignment, submission, result, result.question ]
    original_attributes = records.map { |record| record.reload.attributes }
    original_counts = [ Submission.count, Question.count, GradingResult.count ]
    expect(AiClient).not_to receive(:build)
    [ AnswerReadingJob, AnswerGradingJob, QuestionGenerationJob ].each do |job|
      expect(job).not_to receive(:perform_later)
    end
    login
    [ student_assignments_path, student_assignment_path(assignment), result_path ].each { |path| get path }

    expect(records.map { |record| record.reload.attributes }).to eq(original_attributes)
    expect([ Submission.count, Question.count, GradingResult.count ]).to eq(original_counts)
  end
end
