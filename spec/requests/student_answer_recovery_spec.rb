require "rails_helper"

RSpec.describe "Student answer recovery", type: :request do
  let(:school) { School.create!(school_code: "RECOVERY") }
  let(:teacher) { Teacher.create!(school: school, user_id: "recovery-teacher", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  let(:assignment) do
    Assignment.create!(teacher: teacher, title: "復帰", point_per_question: 5).tap do |item|
      item.assignment_classrooms.create!(classroom: classroom)
      item.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/pdf_preview_single.pdf")),
        filename: "quiz.pdf", content_type: "application/pdf")
    end
  end
  let(:url) { recovery_student_assignment_answer_draft_path(assignment) }
  let(:headers) do
    { "X-Draft-Context" => AnswerDraftContext.issue(student, assignment),
      "X-Recovery-Context" => AnswerDraftContext.issue_recovery(student, assignment) }
  end
  let(:data) { { format_version: 1, pages: [ { page_number: 1, operations: [] } ] } }

  def login(who, password)
    post student_login_path, params: { student_session: { school_code: who.classroom.school.school_code,
      grade: who.classroom.grade, class_number: who.classroom.class_number,
      attendance_number: who.attendance_number, password: password } }
    expect(response).to have_http_status(:see_other)
  end

  it "requires the original student's fresh session and returns a working CSRF token" do
    login(student, "password123")
    get url, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("draft" => nil)
    expect(response.headers["Cache-Control"]).to include("no-store")

    student.update!(password: "65820473")
    get url, headers: headers
    expect(response).to have_http_status(:unauthorized)
    login(student, "65820473")
    get url, headers: headers
    expect(response).to have_http_status(:ok)
    token = response.parsed_body.fetch("csrf_token")
    expect(token).to be_present

    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    put student_assignment_answer_draft_path(assignment),
      params: { expected_version: nil, draft_data: data },
      headers: headers.merge("X-CSRF-Token" => "stale-token"), as: :json
    expect(response.parsed_body).to eq("error" => "csrf_failed")
    expect(response).to have_http_status(:unprocessable_content)
    expect(AnswerDraft.count).to eq(0)

    put student_assignment_answer_draft_path(assignment),
      params: { expected_version: nil, draft_data: data },
      headers: headers.merge("X-CSRF-Token" => token), as: :json
    expect(response).to have_http_status(:ok)
    expect(AnswerDraft.find_by!(student: student, assignment: assignment).lock_version).to eq(0)
  ensure
    ActionController::Base.allow_forgery_protection = previous unless previous.nil?
  end

  it "does not issue recovery for a different student or another school" do
    context = headers
    other = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    login(other, "password123")
    get url, headers: context
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).not_to have_key("csrf_token")

    foreign = School.create!(school_code: "RECOVERY2")
    room = Classroom.create!(school: foreign, grade: 1, class_number: 1)
    outsider = Student.create!(classroom: room, attendance_number: 1, password: "password123")
    login(outsider, "password123")
    get url, headers: context
    expect(response).to have_http_status(:not_found)
  end

  it "rejects a stale handwritten submission CSRF token without creating an answer" do
    login(student, "password123")
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    upload = fixture_file_upload(Rails.root.join("spec/fixtures/files/pdf_preview_single.pdf"), "application/pdf")
    post student_assignment_submission_path(assignment),
      params: { submission: { answer_file: upload }, draft_version: "", submission_token: SecureRandom.uuid },
      headers: { "X-Handwritten-Submission" => "1", "X-CSRF-Token" => "stale-token" }.merge(headers)
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body).to eq("error" => "csrf_failed")
    expect(Submission.where(student: student, assignment: assignment)).to be_empty
  ensure
    ActionController::Base.allow_forgery_protection = previous unless previous.nil?
  end

  it "rejects changed class, material, and prior submission" do
    context = headers
    login(student, "password123")
    second_room = Classroom.create!(school: school, grade: 1, class_number: 2)
    assignment.assignment_classrooms.create!(classroom: second_room)
    student.update!(classroom: second_room)
    get url, headers: context
    expect(response).to have_http_status(:conflict)

    student.update!(classroom: classroom)
    assignment.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/pdf_preview_three.pdf")),
      filename: "changed.pdf", content_type: "application/pdf")
    get url, headers: context
    expect(response).to have_http_status(:conflict)

    fresh_headers = { "X-Draft-Context" => AnswerDraftContext.issue(student, assignment),
      "X-Recovery-Context" => AnswerDraftContext.issue_recovery(student, assignment) }
    Submission.create!(student: student, assignment: assignment, status: :submitted, submitted_at: Time.current)
    get url, headers: fresh_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("submitted" => true, "submission_token" => nil)
    expect(response.parsed_body).not_to have_key("csrf_token")
  end
end
