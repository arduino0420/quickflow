require "rails_helper"

RSpec.describe "Student grading results", type: :request do
  let(:school) { School.create!(school_code: "RESULTS") }
  let(:teacher) { Teacher.create!(school: school, user_id: "results-teacher", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1) }
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
    student_assignment_path(item)
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
    result = item.grading_results.build(question: question, student_answer: "本人の解答", ai_judgment: judgment,
      teacher_judgment: teacher_judgment, ai_model_name: "test-model", prompt_version: "v1",
      graded_at: Time.current, **details)
    result.save!(validate: question.assignment_id == item.assignment_id) # Preserve historical-corruption defenses.
    result
  end

  { nil => "未提出", submitted: "採点待ち", grading: "採点中", completed: "採点完了", failed: "採点失敗" }.each do |state, label|
    it "shows #{label} with one action leading to handwriting or existing results" do
      assignment
      if state
        result_for
        submission.update!(status: state)
      end
      login
      get student_assignments_path

      expect(list_row.text).not_to include("採点完了", "採点中", "採点待ち", "採点失敗", "未提出", "暫定")
      if state == :completed
        expect(list_row.text).to include("5点")
        expect(list_row.at_css("a[href='#{result_path}']")).to be_present
      elsif state.nil?
        expect(list_row.at_css(".student-card-score").text).to eq("")
      else
        expect(list_row.at_css(".student-card-score").text).to eq("")
        expect(list_row.text).not_to include("0点")
      end
      expect(list_row[:class].split.include?("assignment-card--submitted")).to eq(!state.nil?)
      expect(list_row.css("a").size).to eq(1)
      expect(list_row.at_css("a")[:href]).to eq(state ? result_path : student_assignment_pdf_preview_path(assignment))
      expect(list_row.at_css("a")[:class]).to include("assignment-card-link")
      expect(list_row.css("a a, a button")).to be_empty
      expect(list_row.text).not_to include("採点状態：", "現在の点数：", "採点結果を見る", "詳細")

      get student_assignment_path(assignment)
      frame = document.at_css("#grading-status")
      if state
        expect(frame.text).to include(label) unless state == :completed
        expect(frame.css(".final-judgment").any?).to eq(state == :completed)
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
    expect(list_row.text).to include("0点")
    expect(list_row.at_css("a[href='#{result_path}']")).to be_present

    get result_path
    expect(document.at_css("#student-score").text).to eq("現在の点数：0点")
  end

  it "shows 70 points for seven correct answers worth ten points each" do
    assignment.update!(point_per_question: 10)
    10.times { |index| result_for(position: index + 1, judgment: index < 7 ? :correct : :incorrect) }
    login
    get result_path

    expect(document.at_css("#student-score").text).to eq("現在の点数：70点")
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
    expect(fields).to eq("AIが読み取ったあなたの回答" => "3", "正答" => "2",
      "フィードバック" => "足し算が違います。\n計算を確認しましょう。")
    expect(response.body).to include("教師による確認が必要です。先生に申告してください。")
    expect(document.at_css("#student-score").text).to eq("現在の点数：5点（暫定）")
    expect(response.body).not_to include("要確認が残るため、現在の得点は暫定です。", "未確認の問題は加点していません。")
    expect(document.css("form, select")).to be_empty
  end

  it "shows provisional zero when every question still needs teacher review" do
    result_for(judgment: :needs_review)
    login
    get student_assignments_path
    expect(list_row.at_css(".student-card-score").text).to eq("0点")
    expect(list_row[:class].split).to include("assignment-card--submitted")
    expect(list_row.at_css("a")[:href]).to eq(result_path)
    expect(response.body).not_to include("要確認が残る得点は暫定です。未確認の問題は加点していません。")
    get result_path

    expect(document.at_css("#student-score").text).to eq("現在の点数：0点（暫定）")
    expect(response.body).not_to include("現在の得点は暫定です。", "未確認の問題は加点していません。")
  end

  it "hides obsolete incorrect explanations after the teacher marks an answer correct" do
    result_for(judgment: :incorrect, teacher_judgment: :correct,
      error_point: "古い誤り箇所", feedback: "古いフィードバック")
    login
    get result_path

    expect(document.at_css(".final-judgment").text).to eq("最終判定：正解")
    expect(document.at_css("#student-score").text).to eq("現在の点数：5点")
    expect(response.body).not_to include("古い誤り箇所", "古いフィードバック")
    expect(document.css("article dl")).to be_empty
  end

  it "does not invent missing explanations when the teacher marks an answer incorrect" do
    result_for(teacher_judgment: :incorrect, student_answer: nil)
    login
    get result_path

    expect(response).to have_http_status(:ok)
    expect(document.at_css(".final-judgment").text).to eq("最終判定：不正解")
    expect(document.at_css("#student-score").text).to eq("現在の点数：0点")
    expect(response.body).to include("読み取り結果がありません。先生に確認してください。", "教師が判定を変更しています。理由は先生に確認してください。")
  end

  [ :correct, :incorrect, :needs_review ].each do |ai|
    it "shows the latest result after a teacher corrects and restores AI #{ai}" do
      result = result_for(judgment: ai)
      teacher_value = ai == :correct ? "incorrect" : "correct"
      original_score = ai == :correct ? "5点" : (ai == :needs_review ? "0点（暫定）" : "0点")
      corrected_score = ai == :correct ? "0点" : "5点"
      login
      get result_path
      expect(document.at_css("#student-score").text).to eq("現在の点数：#{original_score}")

      post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
      patch assignment_submission_path(assignment, submission), params: { judgments: { result.id.to_s => teacher_value }, original_final_judgments: { result.id.to_s => result.reload.final_judgment } }
      expect(response).to have_http_status(:see_other)
      login
      get result_path
      expect(document.at_css("#student-score").text).to eq("現在の点数：#{corrected_score}")
      expect(document.at_css(".final-judgment").text).to eq("最終判定：#{teacher_value == 'correct' ? '正解' : '不正解'}")
      get student_assignments_path
      expect(list_row.text).to include("#{corrected_score}")

      post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
      patch assignment_submission_path(assignment, submission), params: { judgments: { result.id.to_s => "" }, original_final_judgments: { result.id.to_s => result.reload.final_judgment } }
      login
      get result_path
      expect(document.at_css("#student-score").text).to eq("現在の点数：#{original_score}")
      get student_assignments_path
      expect(list_row.at_css(".student-card-score").text).to eq(ai == :correct ? "5点" : "0点")
    end
  end

  [ :submitted, :grading, :failed ].each do |state|
    it "does not publish stored results or correct answers while #{state}" do
      result = result_for(judgment: :incorrect, student_answer: "非公開の解答", error_point: "非公開の説明")
      result.question.update!(correct_answer: "非公開の正答")
      submission.update!(status: state)
      login
      get result_path

      expect(response).to have_http_status(:ok)
      expect(document.css("article")).to be_empty
      expect(response.body).not_to include("非公開の解答", "非公開の説明", "非公開の正答")
      expect(document.at_css("#grading-status").text).not_to include("採点が完了しました。")
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
      expect(list_row.at_css(".student-card-score").text).to eq("")
      expect(list_row.at_css("a[href='#{result_path}']")).to be_present
      get result_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("採点結果を表示できません。先生に確認してください")
      expect(document.at_css("#student-score").text).to eq("現在の点数：—")
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
    expect(document.at_css("#student-score").text).to eq("現在の点数：0点")
    expect { Rails.application.routes.recognize_path("/student/submissions/#{other_submission.id}", method: :get) }
      .to raise_error(ActionController::RoutingError)
  end

  it "does not borrow a classmate's completed results when the logged-in person has not submitted" do
    other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    other_submission = Submission.create!(assignment: assignment, student: other_student, status: :completed, submitted_at: Time.current)
    result_for(other_submission, judgment: :incorrect, student_answer: "他人だけの解答")
    login
    get student_assignments_path
    expect(list_row.at_css(".student-card-score").text).to eq("")
    get result_student_assignment_path(assignment)

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
      expect(document.css("#grading-status a, #grading-status button")).to be_empty

      submission.update!(status: state)
      get student_assignment_path(assignment), headers: { "Turbo-Frame" => "grading-status" }
      expect(document.at_css("#grading-status [data-controller='grading-status']")).to be_nil
      if state == :completed
        expect(document.at_css("#grading-status .final-judgment").text).to include("正解")
        expect(document.at_css("#student-score").text).to include("5点")
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

  it "shows material details above the read-only answer PDF and results in the same page" do
    result_for(judgment: :incorrect, error_point: "計算の誤り", feedback: "符号を確認しましょう")
    assignment.material_file.attach(io: StringIO.new("%PDF-1.4\nmaterial"), filename: "material.pdf", content_type: "application/pdf")
    submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nmy answer"), filename: "my-answer.pdf", content_type: "application/pdf")
    login
    get student_assignments_path
    expect(list_row.css("a").size).to eq(1)
    get list_row.at_css("a")[:href]
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(assignment.title, "最終判定：不正解", "符号を確認しましょう")
    expect(document.at_css("main").text).not_to include("提出日時:", "my-answer.pdf", "提出済み", "教材ファイル名", "採点が完了しました。", "採点状態：採点完了")
    expect(document.at_css("a[href='#{material_student_assignment_path(assignment, download: "1")}']")).to be_nil
    expect(response.body).not_to include("教材を開く", "答案PDFを開く", "答案をダウンロード")
    expect(document.at_css("h1").text).to eq("#{assignment.title}の採点結果")
    expect(document.at_css(".teacher-review-layout [data-controller='answer-pdf']")[:'data-answer-pdf-url-value']).to eq(answer_student_assignment_path(assignment))
    expect(document.css("form, select:not([data-answer-pdf-target='page']), input, button")).to be_empty
    expect(response.body).not_to include("AIの判定に戻す", "判定を保存")

    get material_student_assignment_path(assignment)
    expect(response.body.b).to eq("%PDF-1.4\nmaterial")
    get answer_student_assignment_path(assignment)
    expect(response.body.b).to eq("%PDF-1.4\nmy answer")
    expect(response.headers["Content-Disposition"]).to include("inline", "my-answer.pdf")
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    get answer_student_assignment_path(assignment, download: "1")
    expect(response.headers["Content-Disposition"]).to include("attachment", "my-answer.pdf")
    assignment.update!(title: "変更後の小テスト名")
    get student_assignment_path(assignment)
    expect(document.at_css("h1").text).to eq("変更後の小テスト名の採点結果")
  end

  it "redirects the legacy results URL to the unified detail without a loop" do
    result_for
    login
    get result_student_assignment_path(assignment)
    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(student_assignment_path(assignment))
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(document.at_css(".final-judgment").text).to include("正解")
  end

  it "serves only the current student's answer even when someone else's IDs are supplied" do
    own_result = result_for
    submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nown"), filename: "own.pdf", content_type: "application/pdf")
    other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    other_submission = Submission.create!(assignment: assignment, student: other_student, status: :completed, submitted_at: Time.current)
    other_submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nother"), filename: "other.pdf", content_type: "application/pdf")
    result_for(other_submission, question: own_result.question)
    login
    get answer_student_assignment_path(assignment), params: { student_id: other_student.id, submission_id: other_submission.id }
    expect(response.body.b).to eq("%PDF-1.4\nown")
    get answer_assignment_submission_path(assignment, other_submission)
    expect(response).to redirect_to(login_path)
  end

  it "does not use a classmate's PDF when the current student has not submitted" do
    other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    other_submission = Submission.create!(assignment: assignment, student: other_student, submitted_at: Time.current)
    other_submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nother"), filename: "other.pdf", content_type: "application/pdf")
    login
    get answer_student_assignment_path(assignment), params: { submission_id: other_submission.id }
    expect(response).to have_http_status(:not_found)
    get student_assignment_path(assignment)
    expect(document.at_css("[data-controller='answer-pdf']")).to be_nil
    expect(document.css("article")).to be_empty
    expect(document.at_css("input[type='file']")).to be_present
  end

  it "rejects direct attempts by a student to change grading through teacher or student URLs" do
    result = result_for(judgment: :incorrect)
    records = [ assignment, submission, result, result.question ]
    original = records.map { |record| record.reload.attributes }
    login
    [ :patch, :put ].each do |method|
      public_send(method, assignment_submission_path(assignment, submission), params: { judgments: { result.id.to_s => "correct" }, original_final_judgments: { result.id.to_s => result.reload.final_judgment } })
      expect(response).to redirect_to(login_path)
      public_send(method, student_assignment_path(assignment), params: { teacher_judgment: "correct", score: 100 })
      expect(response).to have_http_status(:not_found)
    end
    post result_student_assignment_path(assignment), params: { judgments: { result.id.to_s => "correct" }, original_final_judgments: { result.id.to_s => result.reload.final_judgment } }
    expect(response).to have_http_status(:not_found)
    expect(records.map { |record| record.reload.attributes }).to eq(original)
  end

  it "returns 404 for missing answer attachments and downloads non-PDF attachments safely" do
    submission
    login
    get answer_student_assignment_path(assignment)
    expect(response).to have_http_status(:not_found)
    submission.answer_file.attach(io: StringIO.new("text answer"), filename: "answer.txt", content_type: "text/plain")
    get student_assignment_path(assignment)
    expect(document.at_css("[data-controller='answer-pdf']")).to be_nil
    expect(document.at_css("a[href='#{answer_student_assignment_path(assignment, download: '1')}']")).to be_nil
    expect(response.body).to include("答案ファイルをPDFとして表示できません。先生に確認してください。")
    get answer_student_assignment_path(assignment)
    expect(response.headers["Content-Disposition"]).to include("attachment")
  end
  [ [ "同じ説明", "同じ説明", "同じ説明" ],
    [ "誤りの説明", nil, "誤りの説明" ],
    [ nil, "確認の助言", "確認の助言" ],
    [ nil, nil, "説明は登録されていません。先生に確認してください。" ] ].each do |error_point, feedback, expected|
    it "combines feedback without duplication for #{[ error_point, feedback ].inspect}" do
      result_for(judgment: :incorrect, error_point: error_point, feedback: feedback)
      login
      get result_path
      fields = document.at_css("article").css("dt, dd").map(&:text).each_slice(2).to_h
      expect(fields["フィードバック"]).to eq(expected)
      expect(fields).not_to have_key("誤り箇所")
      expect(fields).not_to have_key("短いフィードバック")
    end
  end

  [ :correct, :needs_review ].each do |ai|
    it "does not present AI #{ai} explanations as the reason for a teacher's incorrect decision" do
      result_for(judgment: ai, teacher_judgment: :incorrect, error_point: "元の説明", feedback: "元の助言")
      login
      get result_path
      expect(document.at_css(".final-judgment").text).to include("不正解")
      expect(document.at_css("article").text).not_to include("元の説明", "元の助言")
      expect(document.at_css("article").text).to include("教師が判定を変更しています。理由は先生に確認してください。")
    end
  end
end
