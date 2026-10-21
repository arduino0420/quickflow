require "rails_helper"

RSpec.describe "Authentication security boundaries", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:school) { School.create!(school_code: "AUTHBOUND") }
  let(:room) { Classroom.create!(school: school, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: room, attendance_number: 1, password: "synthetic-secret") }
  let(:teacher) { Teacher.create!(school: school, user_id: "auth-teacher", password: "synthetic-secret") }
  let(:admin) { Admin.create!(school: school, user_id: "auth-admin", password: "synthetic-secret") }
  let(:assignment) do
    Assignment.create!(teacher: teacher, title: "Auth boundaries", point_per_question: 5).tap do |item|
      item.assignment_classrooms.create!(classroom: room)
      item.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/pdf_preview_single.pdf")), filename: "quiz.pdf", content_type: "application/pdf")
    end
  end

  def login(role, actor = public_send(role), password: "synthetic-secret", source: "192.0.2.20", browser: self)
    path, input = case role
    when :student
      [ student_login_path, { student_session: { school_code: school.school_code, grade: "1", class_number: "1",
        attendance_number: actor.attendance_number.to_s, password: password } } ]
    when :teacher
      [ login_path, { session: { user_id: actor.user_id, password: password } } ]
    when :admin
      [ admin_login_path, { admin_session: { user_id: actor.user_id, password: password } } ]
    end
    browser.post path, params: input, headers: { "REMOTE_ADDR" => source }
  end

  def protected_path(role)
    { student: student_assignments_path, teacher: assignments_path, admin: admin_root_path }.fetch(role)
  end

  [ :student, :teacher, :admin ].each do |role|
    it "limits #{role} login without disclosing credentials, and permits logout while limited" do
      actor = public_send(role)
      10.times { login(role, actor, password: "wrong"); expect(response.status).to eq(422) }
      login(role, actor)
      expect(response.status).to eq(429)
      expect(response.headers["Retry-After"].to_i).to be_between(1, 600)
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(response.body).not_to include(actor.password_digest, "wrong")
      delete({ student: student_logout_path, teacher: logout_path, admin: admin_logout_path }.fetch(role))
      expect(response.status).to eq(303)
    end

    it "rejects both #{role} browsers after password change, and accepts a fresh login" do
      actor = public_send(role)
      other = ActionDispatch::Integration::Session.new(Rails.application)
      login(role, actor)
      login(role, actor, browser: other)
      expect(other.response.status).to eq(303)
      replacement = role == :student ? "837416205938174" : "Replacement #{role} Passphrase 482"
      actor.update!(password: replacement)
      get protected_path(role)
      expect(response.status).to eq(303)
      other.get protected_path(role)
      expect(other.response.status).to eq(303)
      login(role, actor, password: replacement)
      get protected_path(role)
      expect(response.status).to eq(200)
    end
  end

  it "expires fixed limits, ignores forged source headers and leaves classmates unaffected" do
    other = Student.create!(classroom: room, attendance_number: 2, password: "synthetic-secret")
    travel_to Time.current.change(usec: 0) do
      10.times { login(:student, password: "wrong") }
      input = { student_session: { school_code: school.school_code, grade: "01", class_number: "01", attendance_number: "01", password: "synthetic-secret" } }
      post student_login_path, params: input, headers: { "REMOTE_ADDR" => "192.0.2.20", "X-Forwarded-For" => "198.51.100.90" }
      expect(response.status).to eq(429)
      login(:student, other)
      expect(response.status).to eq(303)
      travel 10.minutes
      login(:student)
      expect(response.status).to eq(303)
    end
  end

  it "returns indistinguishable responses and limits for known and unknown IDs" do
    teacher
    unknown = Teacher.new(user_id: "unknown-account")
    [ teacher, unknown ].each do |actor|
      10.times do
        login(:teacher, actor, password: "wrong")
        expect(response.status).to eq(422)
        expect(response.body).to include("ユーザーIDまたはパスワードが正しくありません。")
      end
      login(:teacher, actor, password: "wrong")
      expect(response.status).to eq(429)
      expect(response.body).to eq("認証の試行回数が上限に達しました。時間をおいて、もう一度お試しください。")
    end
  end

  it "keeps an existing lesson authenticated during a targeted login lock and never clears limits on logout" do
    login(:student)
    10.times { login(:student, password: "wrong") }
    login(:student)
    expect(response.status).to eq(429)
    get student_assignments_path
    expect(response.status).to eq(200)
    delete student_logout_path
    expect(response.status).to eq(303)
    login(:student)
    expect(response.status).to eq(429)
  end

  it "returns 503 with no new authentication if counter storage fails" do
    teacher
    allow(AuthenticationAttemptBucket).to receive(:insert_all).and_raise(ActiveRecord::ConnectionNotEstablished)
    login(:teacher)
    expect(response.status).to eq(503)
    expect(request.session[:teacher_id]).to be_nil
    get assignments_path
    expect(response.status).to eq(303)
  end

  it "rejects admin reauthentication on storage failure without changing the target" do
    login(:admin)
    original = student.attributes
    allow(AuthenticationAttemptBucket).to receive(:insert_all).and_raise(ActiveRecord::ConnectionNotEstablished)
    reset_student(password: "synthetic-secret")
    expect(response.status).to eq(503)
    expect(student.reload.attributes).to eq(original)
    get admin_root_path
    expect(response.status).to eq(200)
  end

  it "does not silently upgrade a legacy cookie missing a credential proof" do
    allow(CredentialSession).to receive(:issue).and_return(nil)
    login(:teacher)
    allow(CredentialSession).to receive(:issue).and_call_original
    get assignments_path
    expect(response.status).to eq(303)
  end

  def reset_student(password: "wrong", target: student)
    get edit_admin_student_password_reset_path(target)
    token = Nokogiri::HTML(response.body).at_css('input[name="edit_token"]')["value"]
    patch admin_student_password_reset_path(target), params: { edit_token: token, confirmed: "1", admin_password: password,
      student: { password: "837416205938174", password_confirmation: "837416205938174" } }, headers: { "REMOTE_ADDR" => "192.0.2.20" }
  end

  it "limits reauthentication across targets and invalidates all admin proof after password change" do
    travel_to Time.current.change(usec: 0) do
      login(:admin)
      other = Student.create!(classroom: room, attendance_number: 2, password: "synthetic-secret")
      5.times { reset_student; expect(response.status).to eq(422) }
      reset_student(password: "synthetic-secret", target: other)
      expect(response.status).to eq(429)
      expect(response.headers["Retry-After"].to_i).to be_between(1, 300)
      expect(other.reload.authenticate("synthetic-secret")).to be_truthy
      travel 5.minutes
      reset_student(password: "synthetic-secret")
      expect(response.status).to eq(303)
      expect(request.session[:admin_reauthentication]).to be_present
      admin.update!(password: "replacement-admin-secret")
      patch admin_student_password_reset_path(other), params: { confirmed: "1", student: { password: "837416205938174", password_confirmation: "837416205938174" } }
      expect(response.status).to eq(303)
      expect(other.reload.authenticate("synthetic-secret")).to be_truthy
    end
  end

  it "returns 401 without redirecting or mutating drafts/submissions after revocation" do
    login(:student)
    token = AnswerDraftContext.issue(student, assignment)
    student.update!(password: "837416205938174")
    original = [ AnswerDraft.count, Submission.count, ActiveStorage::Blob.count ]
    headers = { "X-Draft-Context" => token, "X-Handwritten-Submission" => "1" }
    get student_assignment_answer_draft_path(assignment), headers: headers
    expect(response.status).to eq(401)
    put student_assignment_answer_draft_path(assignment), params: { expected_version: nil, draft_data: { format_version: 1, pages: [] } }, as: :json, headers: headers
    expect(response.status).to eq(401)
    get student_assignment_submission_path(assignment), headers: headers
    expect(response.status).to eq(401)
    post student_assignment_submission_path(assignment), headers: headers
    expect(response.status).to eq(401)
    expect(response.headers["Location"]).to be_nil
    expect([ AnswerDraft.count, Submission.count, ActiveStorage::Blob.count ]).to eq(original)
  end
  def valid_draft_data
    { format_version: 1, pages: [ { page_number: 1, operations: [ { id: 1, tool: "pen", width: 1.2,
      color: "#000000", points: [ [ 20, 30 ] ] } ] } ] }
  end

  it "finishes a draft already authenticated before a password change, then rejects new saves" do
    login(:student)
    token = AnswerDraftContext.issue(student, assignment)
    changed = false
    allow_any_instance_of(Student::AnswerDraftsController).to receive(:valid_context?).and_wrap_original do |original|
      result = original.call
      unless changed
        student.update!(password: "837416205938174")
        changed = true
      end
      result
    end
    path = student_assignment_answer_draft_path(assignment)
    put path, params: { expected_version: nil, draft_data: valid_draft_data }, as: :json, headers: { "X-Draft-Context" => token }
    expect(response.status).to eq(200)
    saved = AnswerDraft.find_by!(student: student, assignment: assignment).attributes
    put path, params: { expected_version: 0, draft_data: valid_draft_data }, as: :json, headers: { "X-Draft-Context" => token }
    expect(response.status).to eq(401)
    expect(AnswerDraft.find_by!(student: student, assignment: assignment).attributes).to eq(saved)
  end

  it "finishes an authenticated submission during a password change without duplicate jobs or PDFs" do
    login(:student)
    token = AnswerDraftContext.issue(student, assignment)
    allow_any_instance_of(Student::SubmissionsController).to receive(:upload_answer_pdf).and_wrap_original do |original, upload|
      result = original.call(upload)
      student.update!(password: "837416205938174")
      result
    end
    path = student_assignment_submission_path(assignment)
    headers = { "X-Draft-Context" => token, "X-Handwritten-Submission" => "1" }
    input = { draft_version: "", submission_token: SecureRandom.uuid,
      submission: { answer_file: fixture_file_upload("pdf_preview_single.pdf", "application/pdf") } }
    expect { post path, params: input, headers: headers }.to change(Submission, :count).by(1)
      .and have_enqueued_job(AnswerReadingJob).exactly(:once)
    expect(response.status).to eq(200)
    submission = Submission.find_by!(student: student, assignment: assignment)
    pdf = submission.answer_file.download
    expect { post path, params: input, headers: headers }.not_to change(Submission, :count)
    expect(response.status).to eq(401)
    expect(submission.reload.answer_file.download).to eq(pdf)
  end
end
