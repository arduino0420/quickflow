require "rails_helper"

RSpec.describe "Student answer drafts", type: :request do
  let(:school) { School.create!(school_code: "DRAFTREQ") }
  let(:teacher) { Teacher.create!(school: school, user_id: "draft-request", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  let(:assignment) do
    Assignment.create!(teacher: teacher, title: "下書き", point_per_question: 5).tap do |item|
      item.assignment_classrooms.create!(classroom: classroom)
      item.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/pdf_preview_single.pdf")), filename: "quiz.pdf", content_type: "application/pdf")
    end
  end
  let(:url) { student_assignment_answer_draft_path(assignment) }
  let(:token) { AnswerDraftContext.issue(student, assignment) }
  let(:headers) { { "X-Draft-Context" => token } }
  let(:data) { { format_version: 1, pages: [ { page_number: 1, operations: [ { id: 1, tool: "pen", width: 1.2, color: "#000000", points: [ [ 20, 30 ] ] } ] } ] } }

  def login(who = student)
    post student_login_path, params: { student_session: { school_code: who.classroom.school.school_code, grade: who.classroom.grade,
      class_number: who.classroom.class_number, attendance_number: who.attendance_number, password: "password123" } }
  end

  def save_draft(version = nil, body = data)
    put url, params: { expected_version: version, draft_data: body }, headers: headers, as: :json
  end

  it "creates and restores a private draft without submitting or grading" do
    login
    expect(AnswerReadingJob).not_to receive(:perform_later)
    expect { save_draft }.not_to change(Submission, :count)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("draft", "version")).to eq(0)
    get url, headers: headers
    expect(response.parsed_body.dig("draft", "pages")).to eq(JSON.parse(data[:pages].to_json))
    expect(response.headers["Cache-Control"]).to include("no-store")
    delete student_logout_path
    login
    get url, headers: headers
    expect(response.parsed_body.dig("draft", "version")).to eq(0)
  end

  it "returns an empty draft before the first save" do
    login
    get url, headers: headers
    expect(response.parsed_body).to eq("draft" => nil, "editable" => true)
  end

  it "requires login on every read and write" do
    get url, headers: headers
    expect(response).to have_http_status(:unauthorized)
    save_draft
    expect(response).to have_http_status(:unauthorized)
  end

  it "isolates students and rejects stale tabs after a shared-device account switch" do
    login
    save_draft
    other = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    login(other)
    get url, headers: headers
    expect(response).to have_http_status(:conflict)
    save_draft
    expect(response).to have_http_status(:conflict)
    other_headers = { "X-Draft-Context" => AnswerDraftContext.issue(other, assignment) }
    get url, headers: other_headers, params: { student_id: student.id }
    expect(response.parsed_body["draft"]).to be_nil
    put url, params: { student_id: student.id, draft_data: data, expected_version: nil }, headers: other_headers, as: :json
    expect(response).to have_http_status(:ok)
    expect(AnswerDraft.where(student: other).count).to eq(1)
    expect(AnswerDraft.where(student: student).count).to eq(1)
  end

  it "rejects other classrooms, schools and historical cross-school distributions" do
    login
    other_class = Classroom.create!(school: school, grade: 1, class_number: 2)
    other_school = School.create!(school_code: "DRAFTOTHER")
    foreign_teacher = Teacher.create!(school: other_school, user_id: "draft-foreign", password: "password123")
    [ [ teacher, other_class ], [ foreign_teacher, classroom ] ].each do |owner, room|
      item = Assignment.create!(teacher: owner, title: "別教材", point_per_question: 5)
      item.assignment_classrooms.build(classroom: room).save!(validate: false)
      [ :get, :put ].each do |method|
        public_send(method, student_assignment_answer_draft_path(item), headers: headers, params: {}, as: :json)
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  it "rejects stale updates and duplicate first creates without overwriting" do
    login
    save_draft
    save_draft(0, data.deep_dup.tap { |d| d[:pages][0][:operations][0][:points] = [ [ 50, 60 ] ] })
    expect(response.parsed_body.dig("draft", "version")).to eq(1)
    [ nil, 0 ].each do |version|
      save_draft(version)
      expect(response).to have_http_status(:conflict)
    end
    expect(AnswerDraft.count).to eq(1)
    expect(AnswerDraft.first.page_data.first["operations"].first["points"]).to eq([ [ 50, 60 ] ])
  end

  it "retains the old draft and rejects changed materials, including the source PDF URL" do
    login
    save_draft
    old = AnswerDraft.first.attributes
    assignment.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/pdf_preview_three.pdf")), filename: "new.pdf", content_type: "application/pdf")
    get url, headers: headers
    expect(response).to have_http_status(:conflict)
    save_draft(0)
    expect(response).to have_http_status(:conflict)
    get material_student_assignment_path(assignment, draft_context: token)
    expect(response).to have_http_status(:conflict)
    get url, headers: { "X-Draft-Context" => AnswerDraftContext.issue(student, assignment) }
    expect(response.parsed_body["error"]).to eq("material_changed")
    expect(AnswerDraft.first.attributes).to eq(old)
  end

  it "refuses new or updated drafts for every existing submission status" do
    login
    save_draft
    submission = Submission.create!(student: student, assignment: assignment, submitted_at: Time.current)
    Submission.statuses.each_key do |status|
      submission.update!(status: status)
      save_draft(0)
      expect(response).to have_http_status(:forbidden)
    end
    expect(AnswerDraft.first.lock_version).to eq(0)
    get url, headers: headers
    expect(response.parsed_body["editable"]).to be(false)
  end

  it "rejects invalid operations, unexpected schema and oversized/malformed JSON" do
    login
    save_draft(nil, data.deep_dup.tap { |d| d[:pages][0][:operations][0][:points] = [ [ "NaN", 0 ] ] })
    expect(response).to have_http_status(:unprocessable_content)
    save_draft(nil, data.merge(format_version: 99))
    expect(response).to have_http_status(:unprocessable_content)
    put url, params: "{invalid secret ink", headers: headers.merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:bad_request)
    expect(response.parsed_body).to eq("error" => "invalid_json")
    put url, params: "x" * (AnswerDraft::MAX_BYTES + 16.kilobytes + 1), headers: headers.merge("CONTENT_TYPE" => "application/json")
    expect(response).to have_http_status(:content_too_large)
    expect(response.parsed_body).to eq("error" => "request_too_large")
    expect(AnswerDraft.count).to eq(0)
  end

  it "deletes drafts only on the owner's explicit quiz deletion and refuses later saves" do
    login
    save_draft
    get url, headers: headers
    expect(AnswerDraft.where(assignment: assignment).count).to eq(1)
    delete student_logout_path
    expect(AnswerDraft.where(assignment: assignment).count).to eq(1)
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
    expect { delete assignment_path(assignment) }.to change(Assignment, :count).by(-1)
    expect(response).to redirect_to(assignments_path)
    expect(AnswerDraft.where(assignment_id: assignment.id)).to be_empty
    login
    save_draft
    expect(response).to have_http_status(:not_found)
    expect(AnswerDraft.where(assignment_id: assignment.id)).to be_empty
    expect(student.reload).to be_persisted
  end

  it "refuses an in-flight save if deletion occurs after the assignment and context were loaded" do
    login
    save_draft
    allow_any_instance_of(Student::AnswerDraftsController).to receive(:check_context).and_wrap_original do |method|
      method.call
      AssignmentDeletion.new.call(Assignment.find(assignment.id), teacher: teacher)
    end
    save_draft(0)
    expect(response).to have_http_status(:not_found)
    expect(Assignment.exists?(assignment.id)).to be(false)
    expect(AnswerDraft.where(assignment_id: assignment.id)).to be_empty
  end

  it "keeps CSRF protection on the JSON write API" do
    login
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    save_draft
    expect(response).to have_http_status(:unprocessable_content)
    expect(AnswerDraft.count).to eq(0)
    expect(response.parsed_body).to eq("error" => "csrf_failed")
    expect(response.headers["Cache-Control"]).to include("no-store")
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
  it "returns safe distinct validation reasons and never replaces the saved answer on rejection" do
    login
    save_draft
    saved = AnswerDraft.first.attributes
    point = data[:pages][0][:operations][0]
    cases = {
      "draft_points_limit" => data.deep_dup.tap { |body| body[:pages][0][:operations][0][:points] = Array.new(AnswerDraft::MAX_POINTS + 1) { [ 0, 0 ] } },
      "draft_operations_limit" => data.deep_dup.tap { |body| body[:pages][0][:operations] = Array.new(AnswerDraft::MAX_OPERATIONS + 1) { |index| point.merge(id: index + 1) } },
      "draft_bytes_limit" => data.deep_dup.tap { |body| body[:pages][0][:operations][0][:points] = Array.new(99_000) { [ 0.12345678901234567, -0.12345678901234567 ] } },
      "draft_pages_limit" => data.merge(pages: Array.new(AnswerDraft::MAX_PAGES + 1) { |index| { page_number: index + 1, operations: [] } }),
      "invalid_data" => data.deep_dup.tap { |body| body[:pages][0][:operations][0][:width] = 99 }
    }
    # Model JSON exceeds 4 MiB, but the request envelope fits the extra 16 KiB.
    byte_body = cases.fetch("draft_bytes_limit")
    dense_point = [ 0.12345678901234567, -0.12345678901234567 ]
    byte_body[:pages][0][:operations][0][:points] = Array.new(AnswerDraft::MAX_BYTES / (JSON.generate(dense_point).bytesize + 1) + 1, dense_point)
    expect(AnswerReadingJob).not_to receive(:perform_later)
    cases.each do |reason, body|
      save_draft(0, body)
      expect(response).to have_http_status(:unprocessable_content), reason
      expect(response.parsed_body).to eq("error" => reason)
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(AnswerDraft.first.attributes).to eq(saved)
    end
  end
  it "acknowledges saves without echoing ink, restores exact coordinates and supports old clients" do
    login
    operations = data[:pages][0][:operations]
    operations.first[:points] = Array.new(8_000) { |index| [ 20 + index / 100_000.0, 30.123456789012345 ] }
    body = { expected_version: nil, draft_data: data }
    put url, params: body, headers: headers.merge("X-Draft-Response" => "acknowledgment"), as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("draft").keys.sort).to eq(%w[updated_at version])
    expect(response.body.bytesize).to be < 200
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(AnswerDraft.find_by!(student: student, assignment: assignment).page_data).to eq(JSON.parse(data[:pages].to_json))
    get url, headers: headers
    expect(response.parsed_body.dig("draft", "pages")).to eq(JSON.parse(data[:pages].to_json))
    save_draft(0)
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("draft", "pages")).to eq(JSON.parse(data[:pages].to_json))
  end
  describe "lossless appended operations" do
    def append_draft(version, pages)
      put url, params: { expected_version: version, append_data: { format_version: 1, pages: pages } },
        headers: headers.merge("X-Draft-Response" => "acknowledgment"), as: :json
    end

    it "negotiates append, preserves every old and new coordinate and rejects a replay" do
      login
      get url, headers: headers.merge("X-Draft-Response" => "acknowledgment")
      expect(response.parsed_body["append_supported"]).to be(true)
      save_draft
      additions = [ data[:pages][0][:operations][0].merge(id: 2, tool: "eraser", width: 8),
        data[:pages][0][:operations][0].merge(id: 3, points: [ [ 20.123456789012345, 30.987654321098765 ] ]) ]
      expect do
        append_draft(0, [ { page_number: 1, operations: additions } ])
      end.not_to have_enqueued_job(AnswerReadingJob)
      expect(response).to have_http_status(:ok)
      expect(response.body.bytesize).to be < 200
      expected = JSON.parse(data[:pages].to_json)
      expected[0]["operations"].concat(JSON.parse(additions.to_json))
      saved = AnswerDraft.find_by!(student: student, assignment: assignment)
      expect(saved.page_data).to eq(expected)
      expect(saved.lock_version).to eq(1)
      before = saved.attributes
      append_draft(0, [ { page_number: 1, operations: additions } ])
      expect(response).to have_http_status(:conflict)
      expect(saved.reload.attributes).to eq(before)
      get url, headers: headers
      expect(response.parsed_body.dig("draft", "pages")).to eq(expected)
    end

    it "rejects nonexistent drafts, malformed additions, duplicate IDs and ambiguous full data" do
      login
      additions = [ { page_number: 1, operations: [] } ]
      append_draft(nil, additions)
      expect(response).to have_http_status(:unprocessable_content)
      expect(AnswerDraft.count).to eq(0)
      save_draft
      saved = AnswerDraft.first.attributes
      stroke = data[:pages][0][:operations][0].merge(id: 2)
      invalid = [ [], [ { page_number: 2, operations: [] } ], [ { page_number: 1, operations: [], extra: true } ],
        [ { page_number: 1, operations: [ stroke.merge(id: 1) ] } ],
        [ { page_number: 1, operations: [ stroke.merge(points: [ [ "NaN", 0 ] ]) ] } ],
        [ { page_number: 1, operations: [ stroke.merge(width: 4) ] } ] ]
      invalid.each do |pages|
        append_draft(0, pages)
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body).to eq("error" => "invalid_data")
        expect(AnswerDraft.first.attributes).to eq(saved)
      end
      put url, params: { expected_version: 0, draft_data: data, append_data: data }, headers: headers, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(AnswerDraft.first.attributes).to eq(saved)
    end

    it "enforces the cumulative point limit even when the appended request fits" do
      login
      save_draft
      before = AnswerDraft.first.attributes
      points = Array.new(AnswerDraft::MAX_POINTS) { [ 0, 0 ] }
      stroke = data[:pages][0][:operations][0].merge(id: 2, points: points)
      append_draft(0, [ { page_number: 1, operations: [ stroke ] } ])
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq("error" => "draft_points_limit")
      expect(AnswerDraft.first.attributes).to eq(before)
    end

    it "enforces the cumulative byte limit without raising either existing limit" do
      login
      point = [ 0.12345678901234567, -0.12345678901234567 ]
      original = data.deep_dup
      original[:pages][0][:operations][0][:points] = Array.new(50_000, point)
      save_draft(nil, original)
      expect(response).to have_http_status(:ok)
      before = AnswerDraft.first.attributes
      addition = original[:pages][0][:operations][0].merge(id: 2)
      expect(JSON.generate(original[:pages]).bytesize).to be < AnswerDraft::MAX_BYTES
      expect(JSON.generate([ { page_number: 1, operations: [ addition, addition.merge(id: 3) ] } ]).bytesize).to be > AnswerDraft::MAX_BYTES
      append_draft(0, [ { page_number: 1, operations: [ addition ] } ])
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq("error" => "draft_bytes_limit")
      expect(AnswerDraft.first.attributes).to eq(before)
    end

    it "keeps authentication, signed context, material conflicts and logging filters" do
      append_draft(nil, [ { page_number: 1, operations: [] } ])
      expect(response).to have_http_status(:unauthorized)
      login
      save_draft
      before = AnswerDraft.first.attributes
      other = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
      delete student_logout_path
      login(other)
      append_draft(0, [ { page_number: 1, operations: [] } ])
      expect(response).to have_http_status(:conflict)
      expect(AnswerDraft.first.attributes).to eq(before)
      delete student_logout_path
      login
      assignment.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")), filename: "new.pdf", content_type: "application/pdf")
      append_draft(0, [ { page_number: 1, operations: [] } ])
      expect(response).to have_http_status(:conflict)
      expect(AnswerDraft.first.attributes).to eq(before)
      filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter("append_data" => "private handwriting")
      expect(filtered.fetch("append_data")).to eq("[FILTERED]")
    end
  end
end
