require "rails_helper"
require_relative "../support/pdf_fixture_builder"

RSpec.describe "PDF readability at upload boundaries", type: :request do
  include PdfFixtureBuilder
  let(:school) { School.create!(school_code: "PDF048") }
  let(:teacher) { Teacher.create!(school: school, user_id: "pdf48", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  let(:assignment) do
    Assignment.create!(teacher: teacher, title: "PDF確認", point_per_question: 5).tap do |item|
      item.assignment_classrooms.create!(classroom: classroom)
      item.material_file.attach(fixture_file_upload("material.pdf", "application/pdf"))
    end
  end

  def upload(bytes = "%PDF-1.7\ninvalid")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), "application/pdf", original_filename: "answer.pdf")
  end

  def counts
    [ Assignment.count, AssignmentClassroom.count, Submission.count, ActiveStorage::Blob.count,
      ActiveStorage::Attachment.count, QuestionGenerationRequest.count ]
  end

  def teacher_post(file)
    post assignments_path, params: { assignment: { title: "PDF確認", point_per_question: 5,
      classroom_ids: [ classroom.id.to_s ], material_file: file } }
  end

  def student_login
    assignment
    post student_login_path, params: { student_session: { school_code: school.school_code,
      grade: 1, class_number: 1, attendance_number: student.attendance_number, password: "password123" } }
  end

  it "rejects a header-bearing broken teacher PDF before any records or jobs" do
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
    classroom
    original = counts
    expect_any_instance_of(ActiveStorage::Blob).not_to receive(:upload_without_unfurling)
    expect { teacher_post(upload) }.not_to have_enqueued_job(QuestionGenerationJob)
    expect(response.status).to eq(422)
    expect(counts).to eq(original)
    expect(response.body).to include("PDFの内容", "PDF確認", "1年1組")
  end

  it "rejects a header-only 25MiB teacher file as invalid rather than accepting a size fixture" do
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
    classroom
    original = counts
    expect_any_instance_of(ActiveStorage::Blob).not_to receive(:upload_without_unfurling)
    teacher_post(upload("%PDF-1.4\n".ljust(25 * 1024 * 1024, "\0")))
    expect(response.status).to eq(422)
    expect(counts).to eq(original)
  end

  it "returns teacher 503 without records when parsing is unavailable" do
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
    classroom
    original = counts
    allow(PdfReadabilityValidator).to receive(:validate!).and_raise(PdfReadabilityValidator::Unavailable)
    expect_any_instance_of(ActiveStorage::Blob).not_to receive(:upload_without_unfurling)
    teacher_post(upload(valid_pdf_bytes))
    expect(response.status).to eq(503)
    expect(counts).to eq(original)
  end

  %w[pdf_preview.pdf browser_answer.pdf].each do |name|
    it "preserves acceptance of #{name} including warnings and browser-generated answers" do
      student_login
      file = fixture_file_upload(name, "application/pdf")
      expect { post student_assignment_submission_path(assignment), params: { submission: { answer_file: file } } }
        .to have_enqueued_job(AnswerReadingJob).exactly(:once)
      expect(response.status).to eq(303)
      expect(student.submissions.sole.answer_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files", name)))
    end
  end

  it "accepts a valid exact-25MiB student PDF" do
    student_login
    post student_assignment_submission_path(assignment), params: { submission: { answer_file: upload(valid_pdf_bytes(size: 25 * 1024 * 1024)) } }
    expect(response.status).to eq(303)
    expect(student.submissions.sole.answer_file.blob.byte_size).to eq(25 * 1024 * 1024)
  end

  [ :invalid, :unavailable ].each do |failure|
    it "preserves handwritten drafts, UUID context and all records after #{failure} parsing" do
      student_login
      draft = AnswerDraft.create!(student: student, assignment: assignment,
        material_fingerprint: AnswerDraftContext.fingerprint(assignment), page_data: [ { page_number: 1, operations: [] } ])
      saved = draft.attributes
      original = counts
      if failure == :unavailable
        allow(PdfReadabilityValidator).to receive(:validate!).and_raise(PdfReadabilityValidator::Unavailable)
      end
      expect do
        post student_assignment_submission_path(assignment), params: { draft_version: draft.lock_version.to_s,
          submission_token: SecureRandom.uuid, submission: { answer_file: failure == :invalid ? upload : upload(valid_pdf_bytes) } },
          headers: { "X-Handwritten-Submission" => "1", "X-Draft-Context" => AnswerDraftContext.issue(student, assignment), "Accept" => "application/json" }
      end.not_to have_enqueued_job(AnswerReadingJob)
      expect(response.status).to eq(failure == :invalid ? 422 : 503)
      expect(response.parsed_body["error"]).to eq(failure == :invalid ? "invalid_pdf" : "pdf_check_unavailable")
      expect(counts).to eq(original)
      expect(draft.reload.attributes).to eq(saved)
    end
  end
end
