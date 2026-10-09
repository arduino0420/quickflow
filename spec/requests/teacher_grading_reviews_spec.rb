require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "Teacher grading reviews", type: :request do
  include_context "AI grading records"

  before do
    assignment.assignment_classrooms.create!(classroom: classroom)
    submission.update!(status: :completed)
    submission.answer_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")),
      filename: "answer.pdf", content_type: "application/pdf")
  end

  def login(owner = teacher)
    post login_path, params: { session: { user_id: owner.user_id, password: "password123" } }
  end

  def result_for(item = submission, judgment: :needs_review, teacher_judgment: nil, position: 1, owner: item.assignment)
    question = create_question(position: position, label: "問題番号#{position}", owner: owner)
    item.grading_results.create!(question: question, student_answer: "生徒解答#{position}",
      ai_judgment: judgment, teacher_judgment: teacher_judgment, review_reason: "判読困難#{position}",
      feedback: "フィードバック#{position}", ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def detail_path(item = submission, parent = item.assignment)
    assignment_submission_path(parent, item)
  end

  def pdf_path(item = submission, parent = item.assignment)
    answer_assignment_submission_path(parent, item)
  end

  it "defaults to unresolved review problems and switches to all judgments without changing the count" do
    pending = result_for
    result_for(judgment: :correct, position: 2)
    result_for(judgment: :incorrect, position: 3)
    result_for(teacher_judgment: :incorrect, position: 4)
    login
    get assignment_path(assignment)
    expect(response).to have_http_status(:ok)
    expect(document.at_css("#pending-review-count").text).to eq("未確認の要確認：1件")
    expect(document.css("#grading-results tbody tr").size).to eq(1)
    expect(document.at_css("#grading-results").text).to include("1年1組", "1番", "問題番号1", "判読困難1")
    expect(document.at_css("#grading-results a")[:href]).to eq("#{detail_path}#question_#{pending.question_id}")
    get document.at_css("a[aria-current]")[:href]
    expect(document.css("#grading-results tbody tr").size).to eq(1)
    get assignment_path(assignment, filter: "all")
    expect(document.css("#grading-results tbody tr").size).to eq(4)
    expect(document.at_css("#pending-review-count").text).to eq("未確認の要確認：1件")
    get assignment_path(assignment, filter: "unexpected")
    expect(document.css("#grading-results tbody tr").size).to eq(1)
  end

  it "shows the PDF and ordered question details with independent AI, teacher and final judgments" do
    result_for(judgment: :correct, teacher_judgment: :incorrect, position: 2)
    result_for(position: 1)
    login
    get detail_path
    expect(response).to have_http_status(:ok)
    expect(document.at_css("iframe")[:src]).to eq(pdf_path)
    expect(document.css("article h3").map(&:text)).to eq([ "問題 問題番号1", "問題 問題番号2" ])
    expect(response.body).to include("3x+2x を計算しなさい。", "生徒解答1", "5x", "判読困難1", "フィードバック1")
    fields = document.css("article").last.css("dt, dd").map(&:text).each_slice(2).to_h
    expect(fields.slice("AI判定", "教師判定", "最終判定")).to eq("AI判定" => "正解", "教師判定" => "不正解", "最終判定" => "不正解")
    expect(document.at_css("#pending-review-count").text).to eq("未確認の要確認：1件")
    expect(document.at_css("form#teacher-judgments")[:action]).to eq(detail_path)
    expect(document.css("select").size).to eq(2)
    expect(response.body).not_to include("/rails/active_storage")
  end

  it "counts problems across authorized submissions but shows only the selected submission's count" do
    result_for
    another_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    another_submission = Submission.create!(assignment: assignment, student: another_student, status: :completed, submitted_at: Time.current)
    result_for(another_submission, position: 2)
    login
    get assignment_path(assignment)
    expect(document.at_css("#pending-review-count").text).to include("2件")
    get detail_path
    expect(document.at_css("#pending-review-count").text).to include("1件")
    expect(response.body).not_to include("生徒解答2")
  end

  it "shows empty states for no pending reviews or no grading results" do
    login
    get assignment_path(assignment)
    expect(response.body).to include("未確認の要確認問題はありません。", "未確認の要確認：0件")
    get assignment_path(assignment, filter: "all")
    expect(response.body).to include("採点結果はまだありません。")
    get detail_path
    expect(response.body).to include("採点結果がありません。")
  end

  { submitted: "採点待ち", grading: "採点中", failed: "採点失敗" }.each do |state, label|
    it "shows #{state} submissions and PDFs with an explicit incomplete notice" do
      submission.update!(status: state)
      login
      [ assignment_path(assignment), assignment_path(assignment, filter: "all") ].each do |path|
        get path
        expect(response.body).to include(label, "採点結果は未完成です。")
        expect(document.at_css("a[href='#{detail_path}']")).to be_present
      end
      get detail_path
      expect(response.body).to include(label, "採点結果は未完成です。", "暫定件数")
      expect(document.at_css("iframe")[:src]).to eq(pdf_path)
      expect(document.css("article")).to be_empty
      get pdf_path
      expect(response).to have_http_status(:ok)
    end
  end

  it "does not present partial results as final while grading is incomplete" do
    result_for
    submission.update!(status: :failed)
    login
    get assignment_path(assignment)
    expect(document.at_css("#grading-results").text).to include("未完成", "採点失敗")
    get detail_path
    expect(document.css("article")).to be_empty
    expect(response.body).to include("未確認の要確認：1件", "暫定件数")
  end

  it "serves the exact PDF inline with private headers and supports a local download" do
    login
    get pdf_path
    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Content-Disposition"]).to include("inline", "answer.pdf")
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    get answer_assignment_submission_path(assignment, submission, download: "1")
    expect(response.headers["Content-Disposition"]).to include("attachment")
  end

  it "returns 404 for an absent attachment and keeps the details readable" do
    submission.answer_file.detach
    login
    get detail_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("答案PDFが添付されていません。")
    expect(document.css("iframe")).to be_empty
    get pdf_path
    expect(response).to have_http_status(:not_found)
  end

  it "returns 404 if the stored file cannot be found" do
    allow_any_instance_of(ActiveStorage::Blob).to receive(:download).and_raise(ActiveStorage::FileNotFoundError)
    login
    get pdf_path
    expect(response).to have_http_status(:not_found)
  end

  it "does not embed non-PDF attachments and only serves them as downloads" do
    submission.answer_file.blob.update!(content_type: "text/html")
    login
    get detail_path
    expect(document.css("iframe")).to be_empty
    get pdf_path
    expect(response.headers["Content-Disposition"]).to include("attachment")
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
  end

  [ :logged_out, :student, :logged_out_after_login ].each do |authentication|
    it "requires teacher authentication for all review routes when #{authentication}" do
      if authentication == :student
        post student_login_path, params: { student_session: { school_code: school.school_code,
          grade: classroom.grade, class_number: classroom.class_number,
          attendance_number: student.attendance_number, password: "password123" } }
      elsif authentication == :logged_out_after_login
        login
        delete logout_path
      end
      [ assignments_path, assignment_path(assignment), detail_path, pdf_path ].each do |path|
        get path
        expect(response).to redirect_to(login_path)
      end
    end
  end

  it "rejects another teacher even in the same school and even if they own the target classroom" do
    other_teacher = Teacher.create!(school: school, user_id: "other", password: "password123")
    classroom.update!(teacher: other_teacher)
    login(other_teacher)
    get assignments_path
    expect(response.body).not_to include(assignment.title)
    [ assignment_path(assignment), detail_path, pdf_path ].each do |path|
      get path
      expect(response).to have_http_status(:not_found)
    end
    login
    get detail_path
    expect(response).to have_http_status(:ok)
  end

  [ :other_school, :undistributed_classroom ].each do |kind|
    it "excludes #{kind} submissions from counts, lists, details and PDF access" do
      target_school = kind == :other_school ? School.create!(school_code: "FOREIGN") : school
      target = Classroom.create!(school: target_school, teacher: teacher, grade: 2, class_number: 1)
      assignment.assignment_classrooms.create!(classroom: target) if kind == :other_school
      student.update!(classroom: target)
      result_for
      submission.update!(status: :grading)
      login
      [ assignment_path(assignment), assignment_path(assignment, filter: "all") ].each do |path|
        get path
        expect(response.body).to include("未確認の要確認：0件")
        expect(response.body).not_to include("2年1組", "問題番号1", "判読困難1")
        expect(document.css("a[href='#{detail_path}']")).to be_empty
      end
      [ detail_path, pdf_path ].each do |path|
        get path
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  it "rejects a teacher from another school" do
    other_school = School.create!(school_code: "FOREIGN")
    other_teacher = Teacher.create!(school: other_school, user_id: "foreign", password: "password123")
    login(other_teacher)
    get assignments_path
    expect(response.body).not_to include(assignment.title)
    [ assignment_path(assignment), detail_path, pdf_path ].each do |path|
      get path
      expect(response).to have_http_status(:not_found)
    end
  end

  it "excludes assignments distributed only to another school" do
    AssignmentClassroom.where(assignment: assignment).delete_all
    target_school = School.create!(school_code: "FOREIGN")
    target = Classroom.create!(school: target_school, teacher: teacher, grade: 2, class_number: 1)
    assignment.assignment_classrooms.create!(classroom: target)
    login
    get assignments_path
    expect(response.body).not_to include(assignment.title)
    [ assignment_path(assignment), detail_path, pdf_path ].each do |path|
      get path
      expect(response).to have_http_status(:not_found)
    end
  end

  it "rejects swapped parent IDs, nonexistent IDs and undistributed assignments" do
    another_assignment = Assignment.create!(teacher: teacher, title: "別の小テスト", point_per_question: 5)
    another_assignment.assignment_classrooms.create!(classroom: classroom)
    login
    [ detail_path(submission, another_assignment), pdf_path(submission, another_assignment),
      assignment_submission_path(assignment, submission.id + 100),
      answer_assignment_submission_path(assignment, submission.id + 100),
      assignment_submission_path(assignment.id + 100, submission),
      answer_assignment_submission_path(assignment.id + 100, submission) ].each do |path|
      get path
      expect(response).to have_http_status(:not_found)
    end
    AssignmentClassroom.where(assignment: assignment).delete_all
    [ assignment_path(assignment), detail_path, pdf_path ].each do |path|
      get path
      expect(response).to have_http_status(:not_found)
    end
  end

  it "does not expose questions belonging to a different assignment" do
    other = Assignment.create!(teacher: teacher, title: "別テスト", point_per_question: 5)
    result_for(owner: other)
    login
    [ assignment_path(assignment, filter: "all"), detail_path ].each do |path|
      get path
      expect(response.body).to include("未確認の要確認：0件")
      expect(response.body).not_to include("生徒解答1", "問題番号1")
    end
  end

  it "escapes stored answer and AI text" do
    result_for.update!(student_answer: "<script>alert(1)</script>", feedback: "<img src=x onerror=alert(1)>")
    login
    get detail_path
    expect(document.css("article script, article img")).to be_empty
    expect(document.at_css("article").text).to include("<script>alert(1)</script>", "<img src=x onerror=alert(1)>")
  end

  describe "saving teacher judgments" do
    def save_judgments(values, parent = assignment)
      patch assignment_submission_path(parent, submission), params: { judgments: values }
    end

    [ [ :correct, "incorrect" ], [ :incorrect, "correct" ],
      [ :needs_review, "correct" ], [ :needs_review, "incorrect" ] ].each do |ai, teacher_value|
      it "saves #{teacher_value} for AI #{ai} and preserves every AI field" do
        result = result_for(judgment: ai)
        original = result.reload.attributes.except("teacher_judgment", "updated_at")
        expect(AiClient).not_to receive(:build)
        expect(AnswerGradingJob).not_to receive(:perform_later)
        login
        save_judgments(result.id.to_s => teacher_value)
        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(detail_path)
        expect(result.reload.teacher_judgment).to eq(teacher_value)
        expect(result.attributes.except("teacher_judgment", "updated_at")).to eq(original)
        follow_redirect!
        expect(response.body).to include("判定を保存しました。")
        expect(document.at_css("select option[selected]")[:value]).to eq(teacher_value)
        fields = document.css("article dt, article dd").map(&:text).each_slice(2).to_h
        expect(fields["AI判定"]).to eq(ai == :needs_review ? "要確認" : (ai == :correct ? "正解" : "不正解"))
        expect(fields["教師判定"]).to eq(teacher_value == "correct" ? "正解" : "不正解")
        expect(fields["最終判定"]).to eq(fields["教師判定"])
        get detail_path
        expect(document.at_css("select option[selected]")[:value]).to eq(teacher_value)
      end
    end

    [ :correct, :incorrect, :needs_review ].each do |ai|
      it "restores the original AI #{ai} by clearing the teacher judgment" do
        result = result_for(judgment: ai, teacher_judgment: :correct)
        login
        save_judgments(result.id.to_s => "")
        expect(response).to have_http_status(:see_other)
        expect(result.reload.teacher_judgment).to be_nil
        expect(result.ai_judgment).to eq(ai.to_s)
        expect(result.final_judgment).to eq(ai.to_s)
        follow_redirect!
        expect(document.at_css("select option[selected]")[:value]).to eq("")
      end
    end

    it "accepts explicit JSON null as a return to AI" do
      result = result_for(teacher_judgment: :incorrect)
      login
      patch detail_path, params: { judgments: { result.id.to_s => nil } }, as: :json
      expect(response).to have_http_status(:see_other)
      expect(result.reload.teacher_judgment).to be_nil
    end

    it "saves multiple problems and updates both counts and the pending-only list" do
      first = result_for
      second = result_for(position: 2)
      login
      save_judgments(first.id.to_s => "correct", second.id.to_s => "incorrect")
      follow_redirect!
      expect(document.at_css("#pending-review-count").text).to include("0件")
      get assignment_path(assignment)
      expect(document.at_css("#pending-review-count").text).to include("0件")
      expect(document.css("#grading-results tbody tr")).to be_empty
      get assignment_path(assignment, filter: "all")
      expect(document.css("#grading-results tbody tr").size).to eq(2)
      save_judgments(first.id.to_s => "")
      follow_redirect!
      expect(document.at_css("#pending-review-count").text).to include("1件")
      get assignment_path(assignment)
      expect(document.at_css("#pending-review-count").text).to include("1件")
      expect(document.css("#grading-results tbody tr").size).to eq(1)
      expect(second.reload.teacher_judgment).to eq("incorrect")
    end

    it "does not save form selection changes until the form is submitted" do
      result = result_for
      original = result.reload.attributes
      login
      get detail_path
      form = document.at_css("form#teacher-judgments")
      expect(form[:method]).to eq("post")
      expect(form.at_css("input[name='_method']")[:value]).to eq("patch")
      select = form.at_css("select")
      expect(select["onchange"]).to be_nil
      expect(select["data-action"]).to be_nil
      select.css("option").each { |option| option.remove_attribute("selected") }
      select.at_css("option[value='correct']")["selected"] = "selected"
      expect(result.reload.attributes).to eq(original)
      get detail_path
      expect(document.at_css("select option[selected]")[:value]).to eq("")
      expect(result.reload.attributes).to eq(original)
    end

    [ "needs_review", "unknown", "0", 1, false, [], { ai_judgment: "correct" } ].each do |invalid|
      it "rejects invalid judgment #{invalid.inspect} without partially saving" do
        first = result_for
        second = result_for(position: 2)
        login
        patch detail_path, params: { judgments: { first.id.to_s => "correct", second.id.to_s => invalid } }, as: :json
        expect(response).to have_http_status(422)
        expect(first.reload.teacher_judgment).to be_nil
        expect(second.reload.teacher_judgment).to be_nil
        expect(document.at_css("[role='alert']")).to be_present
      end
    end

    [ nil, {}, [], "correct" ].each do |invalid|
      it "rejects a malformed or empty payload #{invalid.inspect}" do
        result = result_for
        login
        patch detail_path, params: { judgments: invalid }, as: :json
        expect(response).to have_http_status(422)
        expect(result.reload.teacher_judgment).to be_nil
      end
    end

    [ "0", "-1", "1abc", "01", "99999999999999999999999999" ].each do |invalid_id|
      it "rejects invalid result ID #{invalid_id} without saving other results" do
        result = result_for
        login
        save_judgments(result.id.to_s => "correct", invalid_id => "incorrect")
        expect([ 404, 422 ]).to include(response.status)
        expect(result.reload.teacher_judgment).to be_nil
      end
    end

    it "ignores extra fields instead of changing AI data or associations" do
      result = result_for
      original = result.reload.attributes.except("teacher_judgment", "updated_at")
      login
      patch detail_path, params: { judgments: { result.id.to_s => "correct" },
        ai_judgment: "incorrect", feedback: "forged", graded_at: "2000-01-01", question_id: 999, submission_id: 999 }
      expect(response).to have_http_status(:see_other)
      expect(result.reload.attributes.except("teacher_judgment", "updated_at")).to eq(original)
    end

    [ :other_submission, :other_assignment_question ].each do |kind|
      it "rejects #{kind} result IDs before any updates" do
        allowed = result_for
        if kind == :other_submission
          other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
          other_submission = Submission.create!(assignment: assignment, student: other_student, status: :completed, submitted_at: Time.current)
          forbidden = result_for(other_submission, position: 2)
        else
          other_assignment = Assignment.create!(teacher: teacher, title: "別テスト", point_per_question: 5)
          forbidden = result_for(owner: other_assignment)
        end
        login
        save_judgments(allowed.id.to_s => "correct", forbidden.id.to_s => "incorrect")
        expect(response).to have_http_status(:not_found)
        expect(allowed.reload.teacher_judgment).to be_nil
        expect(forbidden.reload.teacher_judgment).to be_nil
      end
    end

    it "rolls back a successful earlier update when a later result cannot be saved" do
      first = result_for
      second = result_for(position: 2)
      original = [ first, second ].map { |result| result.reload.attributes }
      saw_first_update = false
      allow_any_instance_of(GradingResult).to receive(:update!).and_wrap_original do |method, *args|
        if method.receiver.id == second.id
          saw_first_update = GradingResult.find(first.id).teacher_judgment == "correct"
          raise ActiveRecord::RecordInvalid.new(method.receiver)
        end
        method.call(*args)
      end
      login
      Submission.transaction do
        save_judgments(first.id.to_s => "correct", second.id.to_s => "incorrect")
        expect(saw_first_update).to be(true)
        expect(response).to have_http_status(422)
        expect([ first, second ].map { |result| result.reload.attributes }).to eq(original)
      end
      expect(response.body).to include("変更は反映されていません。")
      expect(document.at_css("#pending-review-count").text).to include("2件")
    end

    [ :submitted, :grading, :failed ].each do |state|
      it "rejects #{state} submissions even with a forged update request" do
        result = result_for
        login
        get detail_path
        submission.update!(status: state)
        save_judgments(result.id.to_s => "correct")
        expect(response).to have_http_status(422)
        expect(result.reload.teacher_judgment).to be_nil
        expect(document.css("form#teacher-judgments")).to be_empty
        expect(document.at_css("iframe")).to be_present
      end
    end

    [ :logged_out, :student, :other_teacher, :other_school_teacher, :undistributed_classroom, :foreign_classroom ].each do |kind|
      it "refuses updates from #{kind}" do
        result = result_for
        case kind
        when :student
          post student_login_path, params: { student_session: { school_code: school.school_code, grade: classroom.grade,
            class_number: classroom.class_number, attendance_number: student.attendance_number, password: "password123" } }
        when :other_teacher, :other_school_teacher
          target_school = kind == :other_teacher ? school : School.create!(school_code: "FOREIGN")
          other_teacher = Teacher.create!(school: target_school, user_id: "other", password: "password123")
          login(other_teacher)
        when :undistributed_classroom, :foreign_classroom
          target_school = kind == :foreign_classroom ? School.create!(school_code: "FOREIGN") : school
          target = Classroom.create!(school: target_school, teacher: teacher, grade: 2, class_number: 1)
          assignment.assignment_classrooms.create!(classroom: target) if kind == :foreign_classroom
          student.update!(classroom: target)
          login
        end
        save_judgments(result.id.to_s => "correct")
        if [ :logged_out, :student ].include?(kind)
          expect(response).to redirect_to(login_path)
        else
          expect(response).to have_http_status(:not_found)
        end
        expect(result.reload.teacher_judgment).to be_nil
      end
    end

    it "rejects swapped URL IDs even for another owned and distributed assignment" do
      result = result_for
      other = Assignment.create!(teacher: teacher, title: "別テスト", point_per_question: 5)
      other.assignment_classrooms.create!(classroom: classroom)
      login
      save_judgments({ result.id.to_s => "correct" }, other)
      expect(response).to have_http_status(:not_found)
      expect(result.reload.teacher_judgment).to be_nil
    end

    it "allows the distributor to update a same-school classroom owned by another teacher" do
      result = result_for
      classroom.update!(teacher: Teacher.create!(school: school, user_id: "other", password: "password123"))
      login
      save_judgments(result.id.to_s => "correct")
      expect(response).to have_http_status(:see_other)
      expect(result.reload.teacher_judgment).to eq("correct")
    end
  end

  it "only reads existing records and does not invoke AI or enqueue grading" do
    result = result_for
    before_records = [ assignment, submission, result, result.question, submission.answer_file.blob ].map { |record| record.reload.attributes }
    expect(AiClient).not_to receive(:build)
    expect(AnswerReadingJob).not_to receive(:perform_later)
    expect(AnswerGradingJob).not_to receive(:perform_later)
    expect(QuestionGenerationJob).not_to receive(:perform_later)
    login
    [ assignment_path(assignment), assignment_path(assignment, filter: "all"), detail_path, pdf_path ].each { |path| get path }
    expect([ assignment, submission, result, result.question, submission.answer_file.blob ].map { |record| record.reload.attributes }).to eq(before_records)
  end
end
