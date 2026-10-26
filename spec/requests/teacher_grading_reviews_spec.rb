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
    result = item.grading_results.build(question: question, student_answer: "生徒解答#{position}",
      ai_judgment: judgment, teacher_judgment: teacher_judgment, review_reason: "判読困難#{position}",
      feedback: "フィードバック#{position}", ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
    result.save!(validate: question.assignment_id == item.assignment_id) # Preserve historical-corruption defenses.
    result
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def detail_path(item = submission, parent = item.assignment)
    assignment_submission_path(parent, item)
  end

  def list_detail_path(item = submission, filter: "all")
    assignment_submission_path(item.assignment, item, classroom_id: "all", filter: filter)
  end

  def pdf_path(item = submission, parent = item.assignment)
    answer_assignment_submission_path(parent, item)
  end

  describe "submission summary and scores" do
    def summary_cells(item = student)
      document.at_css("#grade-summary #grade_student_#{item.id}").css("td").map { |cell| cell.text.strip }
    end

    def grade_cells(item = student)
      document.at_css("#grade_student_#{item.id}").css(".grade-attendance, .grade-score").map { |cell| cell.text.strip }
    end

    it "includes unsubmitted students without creating submissions and links only submitted answers" do
      unsubmitted = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
      result_for(judgment: :correct)
      login
      original_count = Submission.count
      get assignment_path(assignment)

      expect(document.css("#grade-summary tbody tr").size).to eq(2)
      expect(summary_cells).to eq([ "1年1組", "1番", "採点完了", "5点", "なし" ])
      expect(summary_cells(unsubmitted)).to eq([ "1年1組", "2番", "未提出", "", "—" ])
      expect(document.css("#grade-summary th").map(&:text)).to eq([ "クラス", "出席番号", "提出状況", "得点", "要確認" ])
      expect(document.css("#grade-summary tbody tr").size).to eq(2)
      expect(grade_cells).to eq([ "1番", "5点" ])
      expect(grade_cells(unsubmitted)).to eq([ "2番", "" ])
      expect(document.at_css("#grade_student_#{student.id} a")[:href]).to eq(list_detail_path)
      expect(document.css("#grade_student_#{unsubmitted.id} a")).to be_empty
      expect(Submission.count).to eq(original_count)
      expect(unsubmitted.submissions).to be_empty
    end

    it "makes only submitted rows navigable and updates the yellow highlight after correction" do
      result = result_for
      unsubmitted = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
      login
      get assignment_path(assignment)
      row = document.at_css("#grade_student_#{student.id}")
      expect(row["data-controller"]).to eq("row-navigation")
      expect(row["data-action"]).to eq("click->row-navigation#open")
      expect(row[:class]).to include("grade-needs-review")
      expect(row.css("a").size).to eq(1)
      expect(row.at_css("a.grade-row-link")[:href]).to eq(list_detail_path)
      expect(row.at_css("a")["tabindex"]).to be_nil
      expect(row.css("a a, a button, form, select")).to be_empty
      expect(row.element_children.map(&:name)).to all(eq("td"))
      empty_row = document.at_css("#grade_student_#{unsubmitted.id}")
      expect(empty_row["data-controller"]).to be_nil
      expect(empty_row[:class]).not_to include("grade-needs-review")
      expect(empty_row.css("a")).to be_empty
      expect(document.css(".review-filters a").map(&:text)).to eq([ "すべての生徒", "要確認のある生徒" ])
      expect(document.at_css(".review-filters a[aria-current]").text).to eq("すべての生徒")
      patch detail_path, params: { judgments: { result.id.to_s => "correct" }, original_final_judgments: { result.id.to_s => result.reload.final_judgment } }
      get assignment_path(assignment)
      expect(document.at_css("#grade_student_#{student.id}")[:class]).not_to include("grade-needs-review")
      expect(document.at_css("#grade_student_#{student.id} .grade-review").text.strip).to eq("なし")
    end

    it "defaults to all classrooms and supports selecting each classroom" do
      later_grade = Classroom.create!(school: school, teachers: [ teacher ], grade: 2, class_number: 1)
      later_class = Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 2)
      [ later_grade, later_class ].each { |target| assignment.assignment_classrooms.create!(classroom: target) }
      Student.create!(classroom: later_grade, attendance_number: 1, password: "password123")
      Student.create!(classroom: later_class, attendance_number: 2, password: "password123")
      Student.create!(classroom: classroom, attendance_number: 3, password: "password123")
      Student.create!(classroom: later_class, attendance_number: 1, password: "password123")
      login
      get assignment_path(assignment)

      expect(document.css("#classroom_id option").map(&:text)).to eq([ "配信したすべてのクラス", "1年1組", "1年2組", "2年1組" ])
      expect(document.at_css("#classroom_id option[selected]")[:value]).to eq("all")

      { classroom => [ "1", "3" ], later_class => [ "1", "2" ], later_grade => [ "1" ] }.each do |target, numbers|
        get assignment_path(assignment, classroom_id: target.id)
        expect(document.at_css("#classroom_id option[selected]")[:value]).to eq(target.id.to_s)
        expect(document.css("#grade-summary tbody tr").map { |row| row.at_css("td").text.strip }).to eq(numbers.map { |number| "#{number}番" })
        expect(document.css("#grade-summary th").map(&:text)).to eq([ "出席番号", "提出状況", "得点", "要確認" ])
      end
    end

    { submitted: "採点待ち", grading: "採点中", failed: "採点失敗" }.each do |state, label|
      it "shows #{state} without a score even if correct results are stored" do
        result_for(judgment: :correct)
        submission.update!(status: state)
        expect_any_instance_of(Submission).not_to receive(:score)
        login
        get assignment_path(assignment)

        expect(summary_cells[2..4]).to eq([ label, "", "—" ])
        expect(grade_cells).to eq([ "1番", "" ])
        expect(document.at_css("#grade_student_#{student.id} a")[:href]).to eq(list_detail_path)
        get detail_path
        expect(document.at_css("#submission-score").text).to eq("現在の得点：—")
      end
    end

    it "shows integer zero as points in both the summary and answer details" do
      result_for(judgment: :incorrect)
      login
      get assignment_path(assignment)
      expect(summary_cells[3]).to eq("0点")
      expect(grade_cells).to eq([ "1番", "0点" ])

      get detail_path
      expect(document.at_css("#submission-score").text).to eq("現在の得点：0点")
    end

    it "shows 70 points for seven correct answers worth ten points each" do
      assignment.update!(point_per_question: 10)
      10.times { |index| result_for(position: index + 1, judgment: index < 7 ? :correct : :incorrect) }
      login
      get assignment_path(assignment)
      expect(summary_cells[3]).to eq("70点")

      get detail_path
      expect(document.at_css("#submission-score").text).to eq("現在の得点：70点")
    end

    { correct: 5, needs_review: 0 }.each do |judgment, points|
      it "shows #{points} as provisional points and counts only unresolved reviews" do
        result_for(judgment: judgment)
        result_for(position: 2)
        result_for(position: 3, teacher_judgment: :incorrect)
        expected_count = judgment == :needs_review ? 2 : 1
        login
        get assignment_path(assignment)
        expect(summary_cells[3..4]).to eq([ "#{points}点（暫定）", "あり（#{expected_count}件）" ])
        expect(grade_cells).to eq([ "1番", "#{points}点（暫定）" ])
        expect(response.body).not_to include("要確認は加点していません。")

        get detail_path
        expect(document.at_css("#submission-score").text).to eq("現在の得点：#{points}点（暫定）")
        expect(response.body).to include("要確認が残るため暫定の得点です。", "要確認は加点していません。")
      end
    end

    it "marks stored review counts as provisional while grading is incomplete" do
      result_for
      submission.update!(status: :grading)
      login
      get assignment_path(assignment)

      expect(summary_cells[2..4]).to eq([ "採点中", "", "あり（1件）（暫定）" ])
    end

    [ :no_questions, :missing_result ].each do |inconsistency|
      it "explains an unavailable completed score for #{inconsistency} without showing zero" do
        if inconsistency == :missing_result
          result_for(judgment: :correct)
          create_question(position: 2, label: "未採点の問題")
        end
        login
        get assignment_path(assignment)
        expect(summary_cells[2]).to eq("採点完了")
        expect(summary_cells[3]).to eq("得点を表示できません（採点結果を確認してください）")
        expect(summary_cells[4]).to eq("—")

        get detail_path
        expect(document.at_css("#submission-score").text).to include("得点を表示できません")
        expect(document.at_css("#submission-score").text).not_to include("0点")
      end
    end

    it "does not count foreign assignment results as points or unresolved reviews" do
      result_for(judgment: :correct)
      other_assignment = Assignment.create!(teacher: teacher, title: "別の小テスト", point_per_question: 5)
      foreign_review = result_for(owner: other_assignment)
      foreign_review.update_columns(student_answer: "別小テストの解答", review_reason: "別小テストの要確認理由")
      result_for(owner: other_assignment, position: 2, judgment: :correct)
      login
      get assignment_path(assignment, filter: "all")

      expect(summary_cells[3]).to include("得点を表示できません")
      expect(summary_cells[4]).to eq("—")
      expect(document.at_css("#pending-review-count").text).to eq("未確認の要確認：0件")
      expect(document.css("#grade-summary tbody tr").size).to eq(1)
      expect(response.body).not_to include("別小テストの解答", "別小テストの要確認理由")
      get detail_path
      expect(document.at_css("#submission-score").text).to include("得点を表示できません")
      expect(response.body).not_to include("別小テストの解答", "別小テストの要確認理由")
    end

    [ :correct, :incorrect, :needs_review ].each do |ai|
      it "updates summary and detail scores after correcting and restoring AI #{ai}" do
        result = result_for(judgment: ai)
        original_label = case ai
        when :correct then "5点"
        when :incorrect then "0点"
        when :needs_review then "0点（暫定）"
        end
        teacher_value = ai == :correct ? "incorrect" : "correct"
        corrected_label = ai == :correct ? "0点" : "5点"
        login
        get assignment_path(assignment)
        expect(summary_cells[3]).to eq(original_label)

        patch detail_path, params: { judgments: { result.id.to_s => teacher_value }, original_final_judgments: { result.id.to_s => result.reload.final_judgment } }
        follow_redirect!
        expect(document.at_css("#submission-score").text).to eq("現在の得点：#{corrected_label}")
        get assignment_path(assignment)
        expect(summary_cells[3]).to eq(corrected_label)
        expect(grade_cells[1]).to eq(corrected_label)
        expect(summary_cells[4]).to eq("なし")

        patch detail_path, params: { judgments: { result.id.to_s => "" }, original_final_judgments: { result.id.to_s => result.reload.final_judgment } }
        follow_redirect!
        expect(document.at_css("#submission-score").text).to eq("現在の得点：#{original_label}")
        get assignment_path(assignment)
        expect(summary_cells[3]).to eq(original_label)
        expect(grade_cells[1]).to eq(original_label)
        expect(summary_cells[4]).to eq(ai == :needs_review ? "あり（1件）" : "なし")
      end
    end

    it "keeps each student's score and review count separate" do
      result = result_for
      other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
      other_submission = Submission.create!(assignment: assignment, student: other_student,
        status: :completed, submitted_at: Time.current)
      other_submission.grading_results.create!(question: result.question, ai_judgment: :needs_review,
        teacher_judgment: :correct, ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
      login
      get assignment_path(assignment)

      expect(summary_cells[3..4]).to eq([ "0点（暫定）", "あり（1件）" ])
      expect(summary_cells(other_student)[3..4]).to eq([ "5点", "なし" ])
      expect(document.at_css("#grade_student_#{other_student.id} a")[:href]).to eq(list_detail_path(other_submission))
    end

    [ :other_school, :undistributed_classroom ].each do |kind|
      it "excludes submitted and unsubmitted students from #{kind}" do
        result = result_for(judgment: :correct)
        target_school = kind == :other_school ? School.create!(school_code: "FOREIGN") : school
        target = Classroom.create!(school: target_school, teachers: [ Teacher.create!(school: target_school, user_id: "foreign-#{SecureRandom.hex(4)}", password: "password123") ], grade: 2, class_number: 1)
        assignment.assignment_classrooms.build(classroom: target).tap { |link| link.save!(validate: false) } if kind == :other_school
        foreign_students = [ 1, 2 ].map do |number|
          Student.create!(classroom: target, attendance_number: number, password: "password123")
        end
        forbidden = Submission.new(assignment: assignment, student: foreign_students.first,
          status: :completed, submitted_at: Time.current)
        forbidden.save!(validate: false) # Historical submission outside the allowed distribution.
        forbidden.grading_results.create!(question: result.question, ai_judgment: :needs_review,
          ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
        login
        get assignment_path(assignment, filter: "all")

        expect(document.css("#grade-summary tbody tr").size).to eq(1)
        expect(summary_cells[3..4]).to eq([ "5点", "なし" ])
        foreign_students.each { |item| expect(document.at_css("#grade_student_#{item.id}")).to be_nil }
        expect(response.body).not_to include("2年1組", detail_path(forbidden))
        expect(document.at_css("#pending-review-count").text).to eq("未確認の要確認：0件")
        get detail_path(forbidden)
        expect(response).to have_http_status(:not_found)
      end
    end

    it "includes a distributed same-school classroom owned by another teacher" do
      other_teacher = Teacher.create!(school: school, user_id: "other", password: "password123")
      classroom.update!(teachers: [ other_teacher ])
      result_for(judgment: :correct)
      login
      get assignment_path(assignment)

      expect(summary_cells[3]).to eq("5点")
      expect(document.at_css("#grade_student_#{student.id} a")[:href]).to eq(list_detail_path)
    end

    it "renders both completed students with their calculated scores" do
      result = result_for(judgment: :correct)
      other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
      other_submission = Submission.create!(assignment: assignment, student: other_student,
        status: :completed, submitted_at: Time.current)
      other_submission.grading_results.create!(question: result.question, ai_judgment: :correct,
        ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
      login
      get assignment_path(assignment)

      expect(document.css("#grade-summary .grade-score").map(&:text)).to eq([ "5点", "5点" ])
    end
  end

  describe "classroom selection" do
    let(:second_classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 2) }
    let(:second_student) { Student.create!(classroom: second_classroom, attendance_number: 1, password: "password123") }
    let(:second_submission) do
      Submission.create!(assignment: assignment, student: second_student, status: :completed, submitted_at: Time.current)
    end

    before do
      assignment.assignment_classrooms.create!(classroom: second_classroom)
    end

    it "defaults to all classrooms ordered by grade and class number rather than creation order" do
      classroom.update!(grade: 2)
      second_student
      login
      get assignment_path(assignment)

      expect(document.at_css("#classroom_id option[selected]")[:value]).to eq("all")
      expect(document.css("#grade-summary tbody tr").map { |row| row[:id] }).to eq([ "grade_student_#{second_student.id}", "grade_student_#{student.id}" ])
    end

    it "limits the unified rows, scores, review states and answer links to the selected class" do
      pending = result_for
      correct = result_for(judgment: :correct, position: 2)
      [ pending, correct ].each do |result|
        second_submission.grading_results.create!(question: result.question, ai_judgment: :correct,
          ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
      end
      submission.update!(status: :grading)
      login
      get assignment_path(assignment)
      expect(document.css("#grade-summary tbody tr").size).to eq(2)
      expect(document.at_css("#grade_student_#{student.id} .grade-review").text.strip).to eq("あり（1件）（暫定）")
      get assignment_path(assignment, classroom_id: second_classroom.id)
      expect(document.css("#grade-summary tbody tr").map { |row| row[:id] }).to eq([ "grade_student_#{second_student.id}" ])
      expect(document.at_css(".grade-score").text).to eq("10点")
      expect(document.at_css(".grade-review").text.strip).to eq("なし")
      expect(document.css("a[href='#{detail_path}']")).to be_empty
      second_submission.update!(status: :failed)
      get assignment_path(assignment, classroom_id: second_classroom.id)
      expect(document.at_css(".grade-status").text).to eq("採点失敗")
      expect(document.at_css(".grade-score").text).to be_empty
      expect(document.at_css(".grade-review").text.strip).to eq("—")
    end

    it "preserves the row filter when changing classes and the class when changing filters" do
      login
      get assignment_path(assignment, filter: "needs_review")
      form = document.at_css("#classroom-selection")
      expect(form[:method]).to eq("get")
      expect(form["data-controller"]).to eq("classroom-selection")
      expect(form.at_css("select")["data-action"]).to eq("change->classroom-selection#submit")
      expect(form.css("input[type=submit], button")).to be_empty
      expect(form.at_css("input[name='filter']")[:value]).to eq("needs_review")
      get form[:action], params: { classroom_id: second_classroom.id, filter: "needs_review" }
      expect(document.at_css("#classroom_id option[selected]")[:value]).to eq(second_classroom.id.to_s)
      links = document.css(".review-filters a")
      expect(links.map { |link| link[:href] }).to eq([
        assignment_path(assignment, classroom_id: second_classroom.id, filter: "all"),
        assignment_path(assignment, classroom_id: second_classroom.id, filter: "needs_review")
      ])
      expect(links.last["aria-current"]).to eq("page")
      get links.first[:href]
      expect(document.at_css("#classroom_id option[selected]")[:value]).to eq(second_classroom.id.to_s)
      expect(document.at_css("#classroom-selection input[name='filter']")).to be_nil
      expect(document.at_css(".review-filters a[aria-current]").text).to eq("すべての生徒")
    end

    it "returns to the answer's classroom after saving a teacher correction" do
      result = result_for(second_submission, judgment: :incorrect)
      login
      get assignment_path(assignment, classroom_id: second_classroom.id)
      get document.at_css("#grade_student_#{second_student.id} a")[:href]
      patch detail_path(second_submission), params: { judgments: { result.id.to_s => "correct" }, original_final_judgments: { result.id.to_s => result.reload.final_judgment } }
      follow_redirect!
      back_link = document.css("a").find { |link| link.text == "小テスト詳細へ戻る" }
      expect(back_link[:href]).to eq(assignment_path(assignment, classroom_id: second_classroom.id))
      get back_link[:href]
      expect(document.at_css("#classroom_id option[selected]")[:value]).to eq(second_classroom.id.to_s)
      expect(document.at_css("#grade-summary tbody tr").css(".grade-attendance, .grade-score").map { |cell| cell.text.strip }).to eq([ "1番", "5点" ])
    end

    it "shows an empty state for a selected classroom without registered students" do
      login
      get assignment_path(assignment, classroom_id: second_classroom.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("選択したクラスに生徒がいません。")
      expect(document.css("#grade-summary tbody tr")).to be_empty
      expect(document.at_css("#pending-review-count").text).to eq("未確認の要確認：0件")
    end

    it "allows an explicitly selected same-school destination assigned to another teacher" do
      other_teacher = Teacher.create!(school: school, user_id: "other", password: "password123")
      second_classroom.update!(teachers: [ other_teacher ])
      second_student
      login
      get assignment_path(assignment, classroom_id: second_classroom.id)
      expect(response).to have_http_status(:ok)
      expect(document.at_css("#grade_student_#{second_student.id}")).to be_present
    end

    [ "", "0", "-1", "abc", "1.5", "1abc", "999999999999999999999999999999", [ "1" ], { id: "1" } ].each do |id|
      it "rejects an explicitly invalid classroom ID #{id.inspect}" do
        login
        get assignment_path(assignment), params: { classroom_id: id }
        expect(response).to have_http_status(:not_found)
      end
    end

    it "rejects a numeric-prefix ID instead of coercing it to a valid classroom" do
      login
      get assignment_path(assignment), params: { classroom_id: "#{classroom.id}abc" }
      expect(response).to have_http_status(:not_found)
    end

    [ :other_school, :undistributed_classroom ].each do |kind|
      it "excludes #{kind} from options and rejects its explicit selection" do
        target_school = kind == :other_school ? School.create!(school_code: "FOREIGN") : school
        target = Classroom.create!(school: target_school, teachers: [ Teacher.create!(school: target_school, user_id: "foreign-#{SecureRandom.hex(4)}", password: "password123") ], grade: 3, class_number: 1)
        assignment.assignment_classrooms.build(classroom: target).tap { |link| link.save!(validate: false) } if kind == :other_school
        login
        get assignment_path(assignment)
        expect(document.css("#classroom_id option").map { |option| option[:value] }).to eq([ "all", classroom.id.to_s, second_classroom.id.to_s ])
        get assignment_path(assignment, classroom_id: target.id)
        expect(response).to have_http_status(:not_found)
      end
    end

    it "rejects another teacher's assignment even with its valid destination ID" do
      other_teacher = Teacher.create!(school: school, user_id: "other", password: "password123")
      login(other_teacher)
      get assignment_path(assignment, classroom_id: second_classroom.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "defaults to all students and filters only rows with pending reviews" do
    pending = result_for
    result_for(judgment: :correct, position: 2)
    result_for(judgment: :incorrect, position: 3)
    result_for(teacher_judgment: :incorrect, position: 4)
    other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    login
    get assignment_path(assignment)
    expect(document.css("#grade-summary tbody tr").size).to eq(2)
    expect(document.css("#submission-summary, #grading-results, [aria-labelledby='unfinished-heading']")).to be_empty
    expect(response.body).not_to include("提出状況・答案確認", "採点結果の確認", "判読困難1")
    get assignment_path(assignment, filter: "needs_review")
    expect(document.css("#grade-summary tbody tr").size).to eq(1)
    expect(document.at_css("#grade_student_#{student.id}")[:class]).to include("grade-needs-review")
    expect(document.at_css("#grade_student_#{student.id} .grade-review").text.strip).to eq("あり（1件）")
    expect(document.at_css("#grade_student_#{other_student.id}")).to be_nil
    expect(document.at_css("#grade-summary a")[:href]).to eq(list_detail_path(filter: "needs_review"))
    get assignment_path(assignment, filter: "unexpected")
    expect(document.css("#grade-summary tbody tr").size).to eq(2)
    expect(pending.reload.teacher_judgment).to be_nil
  end

  it "shows the PDF and ordered question details with independent AI, teacher and final judgments" do
    result_for(judgment: :correct, teacher_judgment: :incorrect, position: 2)
    result_for(position: 1)
    login
    get detail_path
    expect(response).to have_http_status(:ok)
    expect(document.at_css("[data-controller='answer-pdf']")[:'data-answer-pdf-url-value']).to eq(pdf_path)
    expect(document.css("article h3").map(&:text)).to eq([ "問題 問題番号1", "問題 問題番号2" ])
    expect(response.body).to include("3x+2x を計算しなさい。", "生徒解答1", "5x", "判読困難1", "フィードバック1")
    fields = document.css("article").last.css("dt, dd").map(&:text).each_slice(2).to_h
    expect(fields.slice("AI判定", "教師判定", "最終判定")).to eq("最終判定" => "不正解")
    expect(document.at_css("#pending-review-count").text).to eq("未確認の要確認：1件")
    expect(document.at_css("form#teacher-judgments")[:action]).to eq(detail_path)
    expect(document.css("form#teacher-judgments select").size).to eq(2)
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

  it "shows a review-filter empty state without hiding the answer in the default view" do
    login
    get assignment_path(assignment, filter: "needs_review")
    expect(response.body).to include("要確認のある生徒はいません。", "未確認の要確認：0件")
    get assignment_path(assignment)
    expect(document.at_css("#grade-summary a")[:href]).to eq(list_detail_path)
    expect(document.at_css(".grade-review").text.strip).to eq("—")
    get detail_path
    expect(response.body).to include("採点結果がありません。")
  end

  { submitted: "採点待ち", grading: "採点中", failed: "採点失敗" }.each do |state, label|
    it "shows #{state} submissions and PDFs with an explicit incomplete notice" do
      submission.update!(status: state)
      login
      [ assignment_path(assignment), assignment_path(assignment, filter: "all") ].each do |path|
        get path
        expect(response.body).to include(label)
        expect(document.at_css("a[href='#{list_detail_path}']")).to be_present
      end
      get detail_path
      expect(response.body).to include(label, "採点結果は未完成です。", "暫定件数")
      expect(document.at_css("[data-controller='answer-pdf']")[:'data-answer-pdf-url-value']).to eq(pdf_path)
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
    expect(document.at_css("#grade-summary").text).to include("採点失敗", "あり（1件）", "（暫定）")
    expect(document.at_css(".grade-score").text).to be_empty
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

  it "highlights only final needs-review cards and updates the card after teacher corrections" do
    pending = result_for
    result_for(position: 2, judgment: :correct)
    result_for(position: 3, judgment: :incorrect)
    login
    get detail_path
    expect(document.css(".teacher-grading-result.judgment-needs_review").map { |card| card[:id] }).to eq([ "question_#{pending.question_id}" ])
    expect(document.at_css("#question_#{pending.question_id}").text).to include("要確認")
    expect(document.at_css("[data-controller='answer-pdf']")[:'data-answer-pdf-url-value']).to eq(pdf_path)
    expect(response.body).not_to include("答案PDFを開く", "答案をダウンロード")
    patch detail_path, params: { judgments: { pending.id.to_s => "correct" }, original_final_judgments: { pending.id.to_s => pending.reload.final_judgment } }
    follow_redirect!
    expect(document.css(".teacher-grading-result.judgment-needs_review")).to be_empty
    expect(document.at_css("#question_#{pending.question_id}")[:class]).to include("judgment-correct")
    fields = document.at_css("#question_#{pending.question_id}").css("dt, dd").map(&:text).each_slice(2).to_h
    expect(fields.slice("AI判定", "最終判定")).to eq("最終判定" => "正解")
    patch detail_path, params: { judgments: { pending.id.to_s => "" }, original_final_judgments: { pending.id.to_s => pending.reload.final_judgment } }
    follow_redirect!
    expect(document.at_css("#question_#{pending.question_id}")[:class]).to include("judgment-needs_review")
  end

  it "returns 404 for an absent attachment and keeps the details readable" do
    submission.answer_file.detach
    login
    get detail_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("答案PDFが添付されていません。")
    expect(document.css("[data-controller='answer-pdf']")).to be_empty
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
    expect(document.css("[data-controller='answer-pdf']")).to be_empty
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
    classroom.update!(teachers: [ other_teacher ])
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
      target = Classroom.create!(school: target_school, teachers: [ Teacher.create!(school: target_school, user_id: "foreign-#{SecureRandom.hex(4)}", password: "password123") ], grade: 2, class_number: 1)
      assignment.assignment_classrooms.build(classroom: target).tap { |link| link.save!(validate: false) } if kind == :other_school
      student.update!(classroom: target)
      result_for
      submission.update_columns(status: :grading) # Historical submission outside its distribution.
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
    target = Classroom.create!(school: target_school, teachers: [ Teacher.create!(school: target_school, user_id: "foreign-#{SecureRandom.hex(4)}", password: "password123") ], grade: 2, class_number: 1)
    assignment.assignment_classrooms.build(classroom: target).tap { |link| link.save!(validate: false) } # Historical foreign distribution.
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
    get assignment_path(assignment)
    expect(response).to have_http_status(:ok)
    expect(document.css("#grade-summary tbody tr, .grade-row-link")).to be_empty
    [ detail_path, pdf_path ].each do |path|
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
      patch assignment_submission_path(parent, submission), params: { judgments: values, original_final_judgments: GradingResult.where(id: values.keys).to_h { |result| [ result.id.to_s, result.final_judgment ] } }
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
        expect(fields).not_to have_key("AI判定")
        expect(fields).not_to have_key("教師判定")
        expect(fields["最終判定"]).to eq(teacher_value == "correct" ? "正解" : "不正解")
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
        expect(document.at_css("select option[selected]")[:value]).to eq(ai == :needs_review ? "" : ai.to_s)
      end
    end

    it "accepts explicit JSON null as a return to AI" do
      result = result_for(teacher_judgment: :incorrect)
      login
      patch detail_path, params: { judgments: { result.id.to_s => nil }, original_final_judgments: { result.id.to_s => result.reload.final_judgment } }, as: :json
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
      expect(document.at_css(".grade-review").text.strip).to eq("なし")
      get assignment_path(assignment, filter: "all")
      expect(document.css("#grade-summary tbody tr").size).to eq(1)
      save_judgments(first.id.to_s => "")
      follow_redirect!
      expect(document.at_css("#pending-review-count").text).to include("1件")
      get assignment_path(assignment)
      expect(document.at_css("#pending-review-count").text).to include("1件")
      expect(document.css("#grade-summary tbody tr").size).to eq(1)
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
        patch detail_path, params: { judgments: { first.id.to_s => "correct", second.id.to_s => invalid },
          original_final_judgments: { first.id.to_s => first.final_judgment, second.id.to_s => second.final_judgment } }, as: :json
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
      patch detail_path, params: { judgments: { result.id.to_s => "correct" }, original_final_judgments: { result.id.to_s => result.reload.final_judgment },
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
        expect(document.at_css("[data-controller='answer-pdf']")).to be_present
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
          target = Classroom.create!(school: target_school, teachers: [ Teacher.create!(school: target_school, user_id: "foreign-#{SecureRandom.hex(4)}", password: "password123") ], grade: 2, class_number: 1)
          assignment.assignment_classrooms.build(classroom: target).tap { |link| link.save!(validate: false) } if kind == :foreign_classroom
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
      classroom.update!(teachers: [ Teacher.create!(school: school, user_id: "other", password: "password123") ])
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
  [ [ :correct, nil ], [ :incorrect, :correct ], [ :needs_review, :correct ] ].each do |ai, correction|
    it "hides reasons and feedback only for final correct (AI #{ai}, teacher #{correction}) without changing stored data" do
      result = result_for(judgment: ai, teacher_judgment: correction)
      original = result.attributes
      login
      get detail_path
      card = document.at_css("#question_#{result.question_id}")
      expect(card.css("dt").map(&:text)).not_to include("要確認理由", "フィードバック")
      expect(card.text).not_to include(result.review_reason, result.feedback)
      expect(result.reload.attributes).to eq(original)
      patch detail_path, params: { final_judgments: { result.id.to_s => "incorrect" }, original_final_judgments: { result.id.to_s => "correct" } }
      follow_redirect!
      card = document.at_css("#question_#{result.question_id}")
      expect(card.css("dt").map(&:text)).to include("要確認理由", "フィードバック")
      expect(card.text).to include(result.review_reason, result.feedback)
    end
  end

  it "keeps reasons and feedback visible for unresolved review and final incorrect" do
    pending = result_for
    incorrect = result_for(position: 2, judgment: :correct, teacher_judgment: :incorrect)
    login
    get detail_path
    [ pending, incorrect ].each do |result|
      card = document.at_css("#question_#{result.question_id}")
      expect(card.css("dt").map(&:text)).to include("要確認理由", "フィードバック")
      expect(card.text).to include(result.review_reason, result.feedback)
    end
  end

  describe "resuming failed grading" do
    include ActiveJob::TestHelper
    self.use_transactional_tests = false
    def resume_path
      resume_grading_assignment_submission_path(assignment, submission)
    end

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("QUICKFLOW_GRADING_RECOVERY_ENABLED").and_return("true")
      submission.update!(status: :failed)
      question = create_question
      question.update!(grading_rule: JSON.generate(criteria: "同類項をまとめる。", requires_work: false,
        material_blob_id: assignment.material_file.blob.id))
      allow_any_instance_of(Recovery::AnswerRecovery).to receive(:queue_clear?).and_return(true)
    end

    after do
      [ @another_assignment, assignment ].compact.each do |item|
        AssignmentDeletion.new.call(item.reload, teacher: item.teacher) if Assignment.exists?(item.id)
      end
      perform_enqueued_jobs(only: ActiveStorage::PurgeJob)
      student.destroy!
      TeacherClassroom.where(classroom_id: classroom.id).delete_all
      classroom.destroy!
      @other_teacher&.destroy!
      teacher.destroy!
      school.destroy!
      @other_school&.destroy!
      clear_enqueued_jobs
    end

    def retry_token_from_page
      document.at_css("input[name='retry_request_token']")[:value]
    end

    it "keeps the feature off by default on GET and POST" do
      allow(ENV).to receive(:[]).with("QUICKFLOW_GRADING_RECOVERY_ENABLED").and_return(nil)
      login
      get detail_path
      expect(document.text).not_to include("採点を再開する")
      expect(Recovery::AnswerRecovery).not_to receive(:new)
      post resume_path
      expect(response).to redirect_to(detail_path)
      follow_redirect!
      expect(document.at_css("[role='alert']").text).to include("現在は採点を再開できません")
      expect(submission.reload).to be_failed
    end

    it "shows a verified CSRF-protected POST button in the right panel" do
      login
      get detail_path
      form = document.at_css("form[action='#{resume_path}']")
      expect(form[:method]).to eq("post")
      expect(form.at_css("button").text).to eq("採点をもう一度依頼する")
      expect(form.ancestors("section").first["aria-labelledby"]).to eq("results-heading")
      expect(document.text).not_to include("採点が完了すると、ここに結果が表示されます。")
    end

    [ "true", nil ].each do |flag|
      it "keeps uncertain registration visible after reload even with feature flag #{flag.inspect}" do
        submission.update!(status: :grading, grading_recovery_attempts: 1,
          grading_recovery_requested_at: 5.minutes.ago, grading_recovery_state: "uncertain")
        allow(ENV).to receive(:[]).with("QUICKFLOW_GRADING_RECOVERY_ENABLED").and_return(flag)
        login
        get detail_path
        expect(document.at_css("#results-heading").text).to include("受付状況を確認できません")
        expect(document.at_css(".grading-retry-button")[:disabled]).not_to be_nil
        expect(document.text).to include("再送せず運用担当者に確認")
        expect(document.text).not_to include("採点が完了すると、ここに結果が表示されます。")
        expect(document.at_css("input[name='retry_request_token']")).to be_nil
        expect(submission.reload.grading_recovery_attempts).to eq(1)
      end
    end

    it "reuses the recovery service and refuses a repeated POST" do
      login
      get detail_path
      request_token = retry_token_from_page
      expect(AnswerGradingJob).to receive(:perform_later).once.and_return(true)
      post resume_path, params: { retry_request_token: request_token }
      expect(response).to redirect_to(detail_path)
      expect(submission.reload).to be_grading
      expect(submission.processing_generation).to eq(1)
      follow_redirect!
      expect(document.at_css("[role='status']").text).to include("再依頼を受け付けました")
      expect(document.text).not_to include("採点を再開する")
      post resume_path, params: { retry_request_token: request_token }
      expect(submission.reload.processing_generation).to eq(1)
      follow_redirect!
      expect(document.at_css("[role='alert']").text).to include("状態が変わりました")
    end

    it "rejects a missing request token without enqueueing" do
      expect(AnswerGradingJob).not_to receive(:perform_later)
      login
      post resume_path
      expect(submission.reload).to be_failed
      follow_redirect!
      expect(document.at_css("[role='alert']").text).to include("画面の情報が古い")
    end

    it "shows and accepts the button for a stopped grading answer" do
      submission.update!(status: :grading, processing_generation: 1)
      allow_any_instance_of(Recovery::AnswerRecovery).to receive(:queue_clear?).and_return(true)
      expect(AnswerGradingJob).to receive(:perform_later).with(have_attributes(id: submission.id), 2, admission: kind_of(String)).and_return(true)
      login
      get detail_path
      expect(document.at_css("form[action='#{resume_path}'] button").text).to eq("採点をもう一度依頼する")
      post resume_path, params: { retry_request_token: retry_token_from_page }
      expect(response).to redirect_to(detail_path)
      expect(submission.reload.processing_generation).to eq(2)
      follow_redirect!
      expect(document.at_css("[role='status']").text).to include("再依頼を受け付けました")
    end

    [ :submitted, :grading, :completed ].each do |state|
      it "does not offer or resume #{state} answers" do
        submission.update!(status: state)
        allow_any_instance_of(Recovery::AnswerRecovery).to receive(:queue_clear?).and_return(false)
        login
        get detail_path
        expect(document.text).not_to include("採点を再開する")
        expect(document.text).to include("画面から採点を再開できません") unless state == :completed
        expect_any_instance_of(Recovery::AnswerRecovery).not_to receive(:call) unless state == :grading
        post resume_path
        expect(submission.reload.status).to eq(state.to_s)
      end
    end

    [ :anonymous, :student, :other_teacher, :foreign_teacher ].each do |actor|
      it "rejects #{actor} before invoking recovery" do
        case actor
        when :student
          post student_login_path, params: { student_session: { school_code: school.school_code,
            grade: classroom.grade, class_number: classroom.class_number,
            attendance_number: student.attendance_number, password: "password123" } }
        when :other_teacher, :foreign_teacher
          target_school = actor == :foreign_teacher ? (@other_school = School.create!(school_code: "FOREIGN")) : school
          login(@other_teacher = Teacher.create!(school: target_school, user_id: "other", password: "password123"))
        end
        expect(Recovery::AnswerRecovery).not_to receive(:new)
        post resume_path
        if [ :anonymous, :student ].include?(actor)
          expect(response).to redirect_to(login_path)
        else
          expect(response).to have_http_status(:not_found)
        end
        expect(submission.reload).to be_failed
      end
    end

    it "rejects an undistributed answer and a swapped assignment ID" do
      login
      another_assignment = @another_assignment = Assignment.create!(teacher: teacher, title: "別テスト", point_per_question: 5)
      another_assignment.assignment_classrooms.create!(classroom: classroom)
      expect(Recovery::AnswerRecovery).not_to receive(:new)
      post resume_grading_assignment_submission_path(another_assignment, submission)
      expect(response).to have_http_status(:not_found)
      AssignmentClassroom.where(assignment: assignment).delete_all
      post resume_path
      expect(response).to have_http_status(:not_found)
      expect(submission.reload).to be_failed
    end

    it "requires a CSRF token when forgery protection is enabled" do
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      get login_path
      token = document.at_css("input[name='authenticity_token']")[:value]
      post login_path, params: { authenticity_token: token,
        session: { user_id: teacher.user_id, password: "password123" } }
      get detail_path
      request_token = retry_token_from_page
      token = document.at_css("form[action='#{resume_path}'] input[name='authenticity_token']")[:value]
      post resume_path
      expect(response).to have_http_status(:unprocessable_content)
      expect(submission.reload).to be_failed
      expect(AnswerGradingJob).to receive(:perform_later).with(have_attributes(id: submission.id), 1, admission: kind_of(String)).once.and_return(true)
      post resume_path, params: { authenticity_token: token, retry_request_token: request_token }
      expect(response).to redirect_to(detail_path)
      expect(submission.reload).to have_attributes(processing_generation: 1, grading_recovery_attempts: 1, status: "grading")
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
  end
end
