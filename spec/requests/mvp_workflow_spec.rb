require "rails_helper"
require_relative "../support/xlsx_inspection"

RSpec.describe "MVP workflow from distribution to Excel export", type: :request do
  include ActiveJob::TestHelper
  include XlsxInspection

  let(:school) { School.create!(school_code: "MVP#{SecureRandom.hex(4)}") }
  let(:teacher) { Teacher.create!(school: school, user_id: "mvp-#{SecureRandom.hex(4)}", password: "password123") }
  let(:classrooms) do
    [ 1, 2 ].map { |number| Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: number) }
  end
  let(:students) do
    classrooms.map { |classroom| Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  end
  let(:files) { instance_double(OpenAI::Resources::Files) }
  let(:responses) { instance_double(OpenAI::Resources::Responses) }
  let(:client) { instance_double(OpenAI::Client, files: files, responses: responses) }

  def teacher_login
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
    expect(response).to redirect_to(assignments_path)
  end

  def student_login(student)
    post student_login_path, params: { student_session: {
      school_code: school.school_code, grade: student.classroom.grade, class_number: student.classroom.class_number,
      attendance_number: student.attendance_number, password: "password123"
    } }
    expect(response).to redirect_to(student_assignments_path)
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def pdf
    fixture_file_upload("material.pdf", "application/pdf")
  end

  def ai_response(data)
    instance_double(OpenAI::Models::Responses::Response, output_text: JSON.generate(data), model: "stub-model",
      status: "completed", output: [])
  end

  before do
    expect(OpenAI::Client).not_to receive(:new)
    allow(AiClient).to receive(:build).and_return(client)
    allow(files).to receive(:create).and_return(double(id: "stub-file"))
    reading_count = 0
    allow(responses).to receive(:create) do |request|
      if request[:instructions]&.include?("添付教材")
        ai_response(questions: (1..3).map { |number|
          { question_label: number.to_s, question_text: "3x+2x", correct_answer: "5x",
            grading_rule: "同類項をまとめる。", requires_work: false }
        })
      elsif request[:instructions].nil?
        reading_count += 1
        problems = (1..3).map do |number|
          blank = reading_count == 2
          unclear = !blank && number == 3
          { question_label: number.to_s, question_text: "3x+2x", student_answer: blank || unclear ? nil : (number == 1 ? "5x" : "6x"),
            reading_status: blank ? "blank" : (unclear ? "unclear" : "readable"), reading_reason: "スタブによる読み取り" }
        end
        ai_response(problems: problems)
      else
        candidates = JSON.parse(request.fetch(:input)).fetch("problems")
        ai_response(results: candidates.map { |problem|
          correct = problem.fetch("question_label") == "1"
          { question_id: problem.fetch("question_id"), ai_judgment: correct ? "correct" : "incorrect",
            error_point: correct ? nil : "係数が違います。", feedback: correct ? nil : "同類項を確認しましょう。", review_reason: nil }
        })
      end
    end
  end

  it "connects both roles, real jobs, shared answers, review, fresh scores and both export scopes" do
    students
    teacher_login
    follow_redirect!
    expect(response).to have_http_status(:ok)
    get new_assignment_path
    expect(response).to have_http_status(:ok)
    post assignments_path, params: { assignment: {
      title: "MVP統合テスト", point_per_question: 5, material_file: pdf, classroom_ids: classrooms.map { |classroom| classroom.id.to_s }
    } }
    expect(response).to have_http_status(:see_other)
    assignment = teacher.assignments.sole
    expect(assignment.classrooms).to match_array(classrooms)
    expect(QuestionGenerationJob).to have_been_enqueued.with(assignment, assignment.material_file.blob.id).once
    perform_enqueued_jobs(only: QuestionGenerationJob)
    expect(assignment.questions.count).to eq(3)
    question_ids = assignment.questions.order(:position).pluck(:id)

    students.each do |student|
      student_login(student)
      follow_redirect!
      row = document.at_css("#assignment_#{assignment.id}")
      expect(row.at_css("a")[:class]).to include("assignment-card-link")
      get row.at_css("a")[:href]
      expect(document.at_css("input[type='file']")).to be_present
      get material_student_assignment_path(assignment)
      expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
      expect {
        post student_assignment_submission_path(assignment), params: { submission: { answer_file: pdf } }
      }.to have_enqueued_job(AnswerReadingJob).with(kind_of(Submission)).once
      expect(response).to have_http_status(:see_other)
      item = student.submissions.find_by!(assignment: assignment)
      expect(item).to be_submitted
      follow_redirect!
      expect(document.at_css("#grading-status").text).to include("採点待ち")
      perform_enqueued_jobs(only: AnswerReadingJob)
      expect(AnswerGradingJob).to have_been_enqueued.with(item).once
      expect(item.reload).to be_grading
      perform_enqueued_jobs(only: AnswerGradingJob)
      expect(item.reload).to be_completed
      expect(item.extracted_text).to be_present
      expect(item.grading_results.count).to eq(3)
      expect(AnswerGradingJob).to have_been_performed.with(item).once
      get student_assignments_path
      row = document.at_css("#assignment_#{assignment.id}")
      expect(row.css("a").size).to eq(1)
      get row.at_css("a")[:href]
      expect(document.at_css("iframe")[:src]).to eq(answer_student_assignment_path(assignment))
      expect(document.css("form, select, input[type='submit']")).to be_empty
    end

    first_submission = students.first.submissions.find_by!(assignment: assignment)
    second_submission = students.last.submissions.find_by!(assignment: assignment)
    expect(first_submission.score).to eq(5)
    expect(second_submission.score).to eq(0)
    expect(assignment.questions.order(:position).pluck(:id)).to eq(question_ids)
    student_login(students.first)
    get student_assignment_path(assignment)
    expect(document.css(".final-judgment").map(&:text)).to eq([ "最終判定：正解", "最終判定：不正解", "最終判定：要確認" ])
    expect(document.at_css("#student-score").text).to include("5点（暫定）")
    result = first_submission.grading_results.find_by!(question_id: question_ids[1])
    review = first_submission.grading_results.find_by!(question_id: question_ids[2])
    original_ai = [ result, review ].map { |item| item.attributes.except("teacher_judgment", "updated_at") }
    patch assignment_submission_path(assignment, first_submission), params: { judgments: { result.id.to_s => "correct" } }
    expect(response).to redirect_to(login_path)
    expect(result.reload.teacher_judgment).to be_nil

    teacher_login
    get assignment_path(assignment)
    expect(document.at_css("#classroom_id option[selected]")[:value]).to eq("all")
    get document.at_css("#grade_student_#{students.first.id} a")[:href]
    expect(document.at_css("iframe")[:src]).to eq(answer_assignment_submission_path(assignment, first_submission))
    patch assignment_submission_path(assignment, first_submission), params: { final_judgments: { result.id.to_s => "correct", review.id.to_s => "incorrect" },
      original_final_judgments: { result.id.to_s => result.final_judgment, review.id.to_s => review.final_judgment } }
    expect(response).to have_http_status(:see_other)
    follow_redirect!
    expect(document.at_css("#submission-score").text).to include("10点")
    expect(first_submission.reload.score).to eq(10)
    expect([ result, review ].map { |item| item.reload.attributes.except("teacher_judgment", "updated_at") }).to eq(original_ai)

    get assignment_path(assignment)
    expect(document.at_css("#grade_student_#{students.first.id} .grade-score").text).to eq("10点")
    get document.css("a").find { |link| link.text == "Excel出力" }[:href]
    sheet = xlsx_worksheet(response.body)
    rows = sheet.xpath("/worksheet/sheetData/row")
    expect(rows.size).to eq(81)
    expect(rows.map { |row| row.xpath("./c").size }).to all(eq(3))
    expect(%w[A1 B1 C1].map { |ref| xlsx_value(sheet, ref) }).to eq([ "クラス", "出席番号", "得点" ])
    expect(%w[A2 B2 C2 A42 B42 C42].map { |ref| xlsx_value(sheet, ref) }).to eq([ "1年1組", "1", "10", "1年2組", "1", "0" ])
    expect(xlsx_cell(sheet, "C42")["t"]).to eq("n")
    expect((3..41).map { |row| xlsx_value(sheet, "C#{row}") }).to all(be_nil)
    get assignment_path(assignment, classroom_id: classrooms.last.id)
    expect(document.at_css("#grade-summary .grade-score").text).to eq("0点")
    get document.css("a").find { |link| link.text == "Excel出力" }[:href]
    sheet = xlsx_worksheet(response.body)
    expect(sheet.xpath("/worksheet/sheetData/row").size).to eq(41)
    expect(%w[A2 B2 C2].map { |ref| xlsx_value(sheet, ref) }).to eq([ "1年2組", "1", "0" ])

    student_login(students.first)
    get student_assignment_path(assignment)
    expect(document.at_css("#student-score").text).to eq("現在の点数：10点")
    expect(document.css(".final-judgment").map(&:text)).to eq([ "最終判定：正解", "最終判定：正解", "最終判定：不正解" ])
    expect(responses).to have_received(:create).exactly(4).times
    expect(files).to have_received(:create).exactly(3).times
  end
end
