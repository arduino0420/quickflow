require "rails_helper"
require_relative "../support/ai_grading_context"
require_relative "../support/xlsx_inspection"

RSpec.describe "Assignment Excel exports", type: :request do
  include_context "AI grading records"
  include XlsxInspection

  before do
    assignment.assignment_classrooms.create!(classroom: classroom)
  end

  def login(owner = teacher)
    post login_path, params: { session: { user_id: owner.user_id, password: "password123" } }
  end

  def export_path(target = classroom, parent = assignment)
    export_assignment_path(parent, classroom_id: target.id)
  end

  def add_result(item, question, judgment)
    item.grading_results.create!(question: question, ai_judgment: judgment,
      ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
  end

  it "downloads the displayed class as a one-sheet xlsx with 40 data rows regardless of the judgment filter" do
    second_classroom = Classroom.create!(school: school, teacher: teacher, grade: 2, class_number: 1)
    assignment.assignment_classrooms.create!(classroom: second_classroom)
    second_student = Student.create!(classroom: second_classroom, attendance_number: 40, password: "password123")
    second_submission = Submission.create!(assignment: assignment, student: second_student, status: :completed, submitted_at: Time.current)
    question = create_question
    another_question = create_question(position: 2)
    add_result(second_submission, question, :correct)
    add_result(second_submission, another_question, :needs_review)
    submission.update!(status: :completed)
    add_result(submission, question, :correct)
    add_result(submission, another_question, :correct)
    login

    [ nil, "all" ].each do |filter|
      get assignment_path(assignment), params: { classroom_id: second_classroom.id, filter: filter }
      document = Nokogiri::HTML(response.body)
      link = document.css("a").find { |node| node.text == "Excel出力" }
      expect(link[:href]).to eq(export_path(second_classroom))
      expect(link["data-turbo"]).to eq("false")
      get link[:href], params: { filter: filter }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
      expect(response.headers["Content-Disposition"]).to start_with("attachment;")
      expect(URI::DEFAULT_PARSER.unescape(response.headers["Content-Disposition"]))
        .to include("課題#{assignment.id}", assignment.title, "2年1組", ".xlsx")
      expect(response.headers["Cache-Control"]).to include("private", "no-store")

      sheet = xlsx_worksheet(response.body)
      expect(sheet.xpath("/worksheet/sheetData/row").size).to eq(41)
      expect(%w[A1 B1 C1].map { |ref| xlsx_value(sheet, ref) }).to eq([ "クラス", "出席番号", "得点" ])
      expect((2..41).map { |row| xlsx_value(sheet, "A#{row}") }).to eq([ "2年1組" ] * 40)
      expect((2..41).map { |row| xlsx_value(sheet, "B#{row}") }).to eq((1..40).map(&:to_s))
      expect((2..40).map { |row| xlsx_value(sheet, "C#{row}") }).to all(be_nil)
      expect(xlsx_value(sheet, "C41")).to eq("5")
      expect(xlsx_cell(sheet, "C41")["t"]).to eq("n")
      Zip::File.open_buffer(StringIO.new(response.body)) do |archive|
        workbook = Nokogiri::XML(archive.read("xl/workbook.xml")).remove_namespaces!
        expect(workbook.xpath("/workbook/sheets/sheet").map { |node| node["name"] }).to eq([ "2年1組" ])
      end
    end
  end

  it "reflects a saved teacher correction in the next download" do
    submission.update!(status: :completed)
    result = add_result(submission, create_question, :incorrect)
    login
    get export_path
    expect(xlsx_value(xlsx_worksheet(response.body), "C2")).to eq("0")

    patch assignment_submission_path(assignment, submission), params: { judgments: { result.id.to_s => "correct" } }
    expect(response).to have_http_status(:see_other)
    get export_path
    expect(xlsx_value(xlsx_worksheet(response.body), "C2")).to eq("5")
  end

  it "downloads 40 blank scores for an empty registered classroom" do
    login
    get export_path
    expect(response).to have_http_status(:ok)
    sheet = xlsx_worksheet(response.body)
    expect(sheet.xpath("/worksheet/sheetData/row").size).to eq(41)
    expect((2..41).map { |row| xlsx_value(sheet, "C#{row}") }).to all(be_nil)
  end

  it "allows a same-school destination belonging to another teacher" do
    other_teacher = Teacher.create!(school: school, user_id: "other", password: "password123")
    classroom.update!(teacher: other_teacher)
    login
    get export_path
    expect(response).to have_http_status(:ok)
    expect(xlsx_value(xlsx_worksheet(response.body), "A2")).to eq("1年1組")
  end

  [ :logged_out, :student ].each do |authentication|
    it "rejects #{authentication} access before generating a workbook" do
      if authentication == :student
        student
        post student_login_path, params: { student_session: {
          school_code: school.school_code, grade: classroom.grade, class_number: classroom.class_number,
          attendance_number: student.attendance_number, password: "password123"
        } }
        expect(response).to redirect_to(student_assignments_path)
      end
      expect(ClassroomGradeExporter).not_to receive(:new)
      get export_path
      expect(response).to redirect_to(login_path)
    end
  end

  [ :same_school, :other_school ].each do |kind|
    it "rejects a different teacher from #{kind}" do
      target_school = kind == :same_school ? school : School.create!(school_code: "FOREIGN")
      other_teacher = Teacher.create!(school: target_school, user_id: "other", password: "password123")
      login(other_teacher)
      expect(ClassroomGradeExporter).not_to receive(:new)
      get export_path
      expect(response).to have_http_status(:not_found)
    end
  end

  [ :other_school, :undistributed ].each do |kind|
    it "rejects a #{kind} classroom even when its ID is supplied directly" do
      target_school = kind == :other_school ? School.create!(school_code: "FOREIGN") : school
      target = Classroom.create!(school: target_school, teacher: teacher, grade: 3, class_number: 1)
      assignment.assignment_classrooms.create!(classroom: target) if kind == :other_school
      login
      expect(ClassroomGradeExporter).not_to receive(:new)
      get export_path(target)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "rejects an undistributed assignment" do
    undistributed = Assignment.create!(teacher: teacher, title: "未配信", point_per_question: 5)
    login
    expect(ClassroomGradeExporter).not_to receive(:new)
    get export_path(classroom, undistributed)
    expect(response).to have_http_status(:not_found)
  end

  it "rejects an omitted classroom ID rather than downloading an unintended default class" do
    login
    expect(ClassroomGradeExporter).not_to receive(:new)
    get export_assignment_path(assignment)
    expect(response).to have_http_status(:not_found)
  end

  [ "", "0", "-1", "abc", "1.5", "999999999999999999999999999999", [ "1" ], { id: "1" } ].each do |id|
    it "rejects invalid classroom ID #{id.inspect}" do
      login
      expect(ClassroomGradeExporter).not_to receive(:new)
      get export_assignment_path(assignment), params: { classroom_id: id }
      expect(response).to have_http_status(:not_found)
    end
  end

  it "rejects an ID with trailing characters instead of coercing it to a valid classroom" do
    login
    get export_assignment_path(assignment), params: { classroom_id: "#{classroom.id}abc" }
    expect(response).to have_http_status(:not_found)
  end
end
