require "rails_helper"
require_relative "../support/ai_grading_context"
require_relative "../support/xlsx_inspection"

RSpec.describe "Batched classroom scores", type: :request do
  include_context "AI grading records"
  include XlsxInspection

  before do
    assignment.assignment_classrooms.create!(classroom: classroom)
    questions = [ create_question, create_question(position: 2) ]
    40.downto(1) do |number|
      pupil = Student.create!(classroom: classroom, attendance_number: number, password: "password123")
      item = Submission.create!(assignment: assignment, student: pupil, status: :completed, submitted_at: Time.current)
      questions.each do |question|
        item.grading_results.create!(question: question, ai_judgment: :needs_review,
          ai_model_name: "synthetic", prompt_version: "v1", graded_at: Time.current)
      end
    end
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
  end

  def capture_score_reads
    events = []
    subscriber = ->(*args) do
      payload = args.last
      events << payload if payload[:sql].match?(/\ASELECT .* FROM "(?:questions|grading_results)"/)
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    expect(response).to have_http_status(:ok)
    questions = events.select { |event| event[:sql].start_with?('SELECT "questions".') }
    results = events.select { |event| event[:sql].start_with?('SELECT "grading_results".* FROM') }
    expect(questions.size).to eq(1)
    expect(results.size).to eq(1)
    expect((questions + results).any? { |event| event[:cached] }).to be(false)
  end

  it "reads scores once for 40 students on normal, filtered, and Excel requests" do
    [ "all", "needs_review" ].each do |filter|
      capture_score_reads { get assignment_path(assignment), params: { classroom_id: classroom.id, filter: filter } }
      rows = Nokogiri::HTML(response.body).css("#grade-summary tbody tr")
      expect(rows.map { |row| row.at_css(".grade-attendance").text.strip }).to eq((1..40).map { |n| "#{n}番" })
      expect(rows.map { |row| row.at_css(".grade-score").text }).to all(eq("0点（暫定）"))
    end
    capture_score_reads { get export_assignment_path(assignment), params: { classroom_id: classroom.id } }
    sheet = xlsx_worksheet(response.body)
    expect((2..41).map { |row| xlsx_value(sheet, "C#{row}") }).to all(eq("0"))
  end
  it "refreshes the student list on an independent request after a teacher correction" do
    pupil = classroom.students.find_by!(attendance_number: 1)
    item = assignment.submissions.find_by!(student: pupil)
    result = item.grading_results.first
    2.times do |index|
      other = Assignment.create!(teacher: teacher, title: "Other #{index}", point_per_question: 7)
      other.assignment_classrooms.create!(classroom: classroom)
      other_submission = Submission.create!(assignment: other, student: pupil, status: :completed, submitted_at: Time.current)
      other_submission.grading_results.create!(question: create_question(owner: other), ai_judgment: :correct,
        ai_model_name: "synthetic", prompt_version: "v1", graded_at: Time.current)
    end
    post student_login_path, params: { student_session: {
      school_code: school.school_code, grade: 1, class_number: 1,
      attendance_number: 1, password: "password123"
    } }
    capture_score_reads { get student_assignments_path }
    expect(Nokogiri::HTML(response.body).at_css("#assignment_#{assignment.id} .student-card-score").text).to eq("0点")

    teacher_session = ActionDispatch::Integration::Session.new(Rails.application)
    teacher_session.post(login_path, params: { session: { user_id: teacher.user_id, password: "password123" } })
    teacher_session.patch(assignment_submission_path(assignment, item), params: {
      judgments: { result.id.to_s => "correct" },
      original_final_judgments: { result.id.to_s => result.final_judgment }
    })
    expect(teacher_session.response).to have_http_status(:see_other)
    capture_score_reads { get student_assignments_path }
    expect(Nokogiri::HTML(response.body).at_css("#assignment_#{assignment.id} .student-card-score").text).to eq("5点")
  end
end
