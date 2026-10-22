require "rails_helper"
require_relative "../support/ai_grading_context"
require_relative "../support/xlsx_inspection"

RSpec.describe "All distributed classroom grades", type: :request do
  include_context "AI grading records"
  include XlsxInspection

  let(:second_classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 2) }
  let(:third_classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 2, class_number: 1) }

  before do
    [ third_classroom, second_classroom, classroom ].each do |target|
      assignment.assignment_classrooms.create!(classroom: target)
    end
    expect(QuestionGenerationJob).not_to receive(:perform_later)
    expect(AnswerReadingJob).not_to receive(:perform_later)
    expect(AnswerGradingJob).not_to receive(:perform_later)
  end

  def login(owner = teacher)
    post login_path, params: { session: { user_id: owner.user_id, password: "password123" } }
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def create_result(target, number, judgment: :correct, status: :completed, historical: false)
    pupil = Student.create!(classroom: target, attendance_number: number, password: "password123")
    item = Submission.new(assignment: assignment, student: pupil, status: status, submitted_at: Time.current)
    item.save!(validate: !historical) # Only out-of-scope fixtures bypass the new submission validation.
    question = assignment.questions.first || create_question
    item.grading_results.create!(question: question, ai_judgment: judgment, review_reason: "確認が必要",
      ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
  end

  def grade_rows
    document.css("#grade-summary tbody tr").map { |row| row.css("td:not(.grade-status):not(.grade-review):not(.grade-answer)").map { |cell| cell.text.strip } }
  end

  it "defaults to all destinations and orders grades, summaries and judgments by class and attendance" do
    create_result(third_classroom, 1)
    pending = create_result(second_classroom, 1, judgment: :needs_review)
    create_result(classroom, 3, judgment: :incorrect)
    create_result(classroom, 1, status: :grading)
    Student.create!(classroom: second_classroom, attendance_number: 2, password: "password123")
    login
    get assignment_path(assignment)

    expect(document.at_css("#classroom_id option[selected]")[:value]).to eq("all")
    expect(document.css("#classroom_id option").map(&:text)).to eq([ "配信したすべてのクラス", "1年1組", "1年2組", "2年1組" ])
    expect(document.css("#grade-summary th").map(&:text)).to eq([ "クラス", "出席番号", "提出状況", "得点", "要確認" ])
    expect(grade_rows).to eq([
      [ "1年1組", "1番", "" ], [ "1年1組", "3番", "0点" ],
      [ "1年2組", "1番", "0点（暫定）" ], [ "1年2組", "2番", "" ], [ "2年1組", "1番", "5点" ]
    ])
    expect(document.css("#grade-summary tbody tr").size).to eq(5)
    expect(document.css("#grade-summary .grade-needs-review").size).to eq(1)
    expect(document.css("#submission-summary, #grading-results, [aria-labelledby='unfinished-heading']")).to be_empty
    review_filter = document.css(".review-filters a").last
    expect(review_filter[:href]).to eq(assignment_path(assignment, classroom_id: "all", filter: "needs_review"))
    get review_filter[:href]
    expect(grade_rows).to eq([ [ "1年2組", "1番", "0点（暫定）" ] ])
    expect(document.at_css("#classroom-selection input[name='filter']")[:value]).to eq("needs_review")

    patch assignment_submission_path(assignment, pending.submission), params: { judgments: { pending.id.to_s => "correct" }, original_final_judgments: { pending.id.to_s => pending.reload.final_judgment } }
    get assignment_path(assignment, classroom_id: "all")
    expect(grade_rows).to include([ "1年2組", "1番", "5点" ])
    expect(document.at_css("#pending-review-count").text).to include("0件")

    get assignment_path(assignment, classroom_id: second_classroom.id)
    expect(document.css("#grade-summary th").map(&:text)).to eq([ "出席番号", "提出状況", "得点", "要確認" ])
    expect(grade_rows).to eq([ [ "1番", "5点" ], [ "2番", "" ] ])
  end

  it "exports one sheet of 121 rows with blank, numeric zero, provisional and corrected scores" do
    create_result(third_classroom, 40)
    pending = create_result(second_classroom, 1, judgment: :needs_review)
    create_result(classroom, 1, judgment: :incorrect)
    create_result(classroom, 2, status: :grading)
    create_result(classroom, 3, status: :failed)
    create_result(classroom, 4, status: :submitted)
    Student.create!(classroom: classroom, attendance_number: 5, password: "password123")
    login
    get assignment_path(assignment)
    link = document.css("a").find { |node| node.text == "Excel出力" }
    expect(link[:href]).to eq(export_assignment_path(assignment, classroom_id: "all"))
    get link[:href]
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    sheet = xlsx_worksheet(response.body)
    rows = sheet.xpath("/worksheet/sheetData/row")
    expect(rows.size).to eq(121)
    expect(rows.map { |row| row.xpath("./c").size }).to all(eq(3))
    expect(%w[A1 B1 C1].map { |ref| xlsx_value(sheet, ref) }).to eq([ "クラス", "出席番号", "得点" ])
    expect((2..121).map { |row| xlsx_value(sheet, "A#{row}") }).to eq([ "1年1組" ] * 40 + [ "1年2組" ] * 40 + [ "2年1組" ] * 40)
    expect((2..121).map { |row| xlsx_value(sheet, "B#{row}") }).to eq((1..40).map(&:to_s) * 3)
    expect(xlsx_value(sheet, "C2")).to eq("0")
    expect(xlsx_cell(sheet, "C2")["t"]).to eq("n")
    expect((3..41).map { |row| xlsx_value(sheet, "C#{row}") }).to all(be_nil)
    expect(xlsx_value(sheet, "C42")).to eq("0")
    expect(xlsx_value(sheet, "C121")).to eq("5")
    Zip::File.open_buffer(StringIO.new(response.body)) do |archive|
      workbook = Nokogiri::XML(archive.read("xl/workbook.xml")).remove_namespaces!
      expect(workbook.xpath("/workbook/sheets/sheet").size).to eq(1)
    end

    patch assignment_submission_path(assignment, pending.submission), params: { judgments: { pending.id.to_s => "correct" }, original_final_judgments: { pending.id.to_s => pending.reload.final_judgment } }
    get export_assignment_path(assignment, classroom_id: "all", filter: "all")
    expect(xlsx_value(xlsx_worksheet(response.body), "C42")).to eq("5")
  end

  it "excludes undistributed and foreign school data even with a foreign distribution link" do
    undistributed = Classroom.create!(school: school, teachers: [ teacher ], grade: 3, class_number: 14)
    foreign_school = School.create!(school_code: "FOREIGN")
    foreign = Classroom.create!(school: foreign_school, teachers: [ Teacher.create!(school: foreign_school, user_id: "foreign-#{SecureRandom.hex(4)}", password: "password123") ], grade: 3, class_number: 15)
    assignment.assignment_classrooms.build(classroom: foreign).tap { |link| link.save!(validate: false) } # Historical foreign distribution.
    [ undistributed, foreign ].each { |target| create_result(target, 1, historical: true) }
    create_result(classroom, 1)
    login
    get assignment_path(assignment, classroom_id: "all", filter: "all")
    expect(grade_rows).to eq([ [ "1年1組", "1番", "5点" ] ])
    expect(response.body).not_to include("3年14組", "3年15組")
    expect(document.css("#grade-summary tbody tr").size).to eq(1)
    get export_assignment_path(assignment, classroom_id: "all")
    sheet = xlsx_worksheet(response.body)
    expect(sheet.xpath("/worksheet/sheetData/row").size).to eq(121)
    expect(sheet.text).not_to include("3年14組", "3年15組")
  end

  [ :other_teacher, :foreign_teacher, :student, :anonymous ].each do |actor|
    it "rejects all-class viewing and export by #{actor}" do
      case actor
      when :other_teacher, :foreign_teacher
        target_school = actor == :foreign_teacher ? School.create!(school_code: "FOREIGN") : school
        login(Teacher.create!(school: target_school, user_id: "other", password: "password123"))
      when :student
        post student_login_path, params: { student_session: {
          school_code: school.school_code, grade: classroom.grade, class_number: classroom.class_number,
          attendance_number: student.attendance_number, password: "password123"
        } }
      end
      expect(ClassroomGradeExporter).not_to receive(:new)
      [ assignment_path(assignment, classroom_id: "all"), export_assignment_path(assignment, classroom_id: "all") ].each do |path|
        get path
        if [ :student, :anonymous ].include?(actor)
          expect(response).to redirect_to(login_path)
        else
          expect(response).to have_http_status(:not_found)
        end
      end
    end
  end
end
