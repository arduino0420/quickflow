require "rails_helper"

RSpec.describe "Student submissions", type: :request do
  include ActiveJob::TestHelper
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "student-password") }
  let(:assignment) do
    item = Assignment.create!(teacher: teacher, title: "式の計算", point_per_question: 5)
    item.assignment_classrooms.create!(classroom: classroom)
    item
  end

  def login
    post student_login_path, params: { student_session: {
      school_code: school.school_code, grade: classroom.grade, class_number: classroom.class_number,
      attendance_number: student.attendance_number, password: "student-password"
    } }
  end

  def pdf
    fixture_file_upload(Rails.root.join("spec/fixtures/files/material.pdf"), "application/pdf")
  end

  def submit(file = pdf, extra = {})
    post student_assignment_submission_path(assignment), params: { submission: extra.merge(answer_file: file) }
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def counts
    [ Submission.count, ActiveStorage::Attachment.count, ActiveStorage::Blob.count ]
  end

  it "submits a PDF with trusted associations, status and time, then hides the form" do
    login
    get student_assignment_path(assignment)
    expect(document.at_css('form[enctype="multipart/form-data"]')).to be_present
    expect(document.at_css('input[type="file"]')[:accept]).to eq("application/pdf,.pdf")
    started = Time.current
    submit(pdf, student_id: student.id + 100, assignment_id: assignment.id + 100,
      status: "completed", submitted_at: "2000-01-01")
    expect(response).to redirect_to(student_assignment_path(assignment))
    expect(response).to have_http_status(:see_other)
    item = Submission.last
    expect(item.student).to eq(student)
    expect(item.assignment).to eq(assignment)
    expect(item).to be_submitted
    expect(item.submitted_at).to be_between(started, Time.current)
    expect(item.answer_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
    follow_redirect!
    expect(response.body).to include("提出しました", "#{assignment.title}の採点結果", "採点待ち")
    expect(Nokogiri::HTML(response.body).at_css("[data-controller='answer-pdf']")[:'data-answer-pdf-url-value']).to eq(answer_student_assignment_path(assignment))
    expect(document.css("form, input")).to be_empty
    expect(document.css("main a").map { |link| link[:href] }).to eq([ student_assignments_path, answer_student_assignment_path(assignment) ])
    expect(document.at_css("#grading-status").text).to include("採点待ち")
    expect(document.at_css("#grading-status [data-controller='grading-status']")).to be_present
  end

  [ nil, "bad", { id: "bad" } ].each do |file|
    it "rejects missing or malformed file #{file.inspect}" do
      login
      before_counts = counts
      submit(file)
      expect(response).to have_http_status(422)
      expect(counts).to eq(before_counts)
      expect(document.at_css('[role="alert"]')).to be_present
      expect(document.at_css('input[type="file"]')[:value]).to be_blank
    end
  end

  [ [ "answer.pdf", "application/pdf", "not a PDF" ],
    [ "answer.txt", "application/pdf", "%PDF-1.4\n" ],
    [ "answer.txt", "text/plain", "text" ] ].each do |filename, type, content|
    it "rejects non-PDF extension or disguised content #{filename} #{content.inspect}" do
      login
      before_counts = counts
      file = Rack::Test::UploadedFile.new(StringIO.new(content), type, original_filename: filename)
      submit(file)
      expect(response).to have_http_status(422)
      expect(counts).to eq(before_counts)
    end
  end

  it "accepts uppercase PDF extension and uses content instead of the declared type" do
    login
    file = Rack::Test::UploadedFile.new(StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      "text/plain", original_filename: "answer.PDF")
    submit(file)
    expect(response).to have_http_status(:see_other)
    expect(Submission.last.answer_file.filename.to_s).to eq("answer.PDF")
  end

  it "rejects an oversized uploaded PDF without creating a submission, attachment or job" do
    login
    header = "%PDF-1.4\n"
    contents = header + ("0" * (Student::SubmissionsController::MAX_PDF_BYTES + 1 - header.bytesize))
    upload = Rack::Test::UploadedFile.new(StringIO.new(contents), "application/pdf", original_filename: "large.pdf")
    before_counts = counts

    expect { submit(upload) }.not_to have_enqueued_job(AnswerReadingJob)
    expect(response).to have_http_status(:content_too_large)
    expect(document.at_css('[role="alert"]').text).to include("答案PDFは25MiB以下のPDFを選択してください")
    expect(counts).to eq(before_counts)
    expect(student.submissions).to be_empty
  end

  it "allows another teacher's assignment distributed to multiple classes including the student's" do
    owner = Teacher.create!(school: school, user_id: "teacher2", password: "password123")
    assignment.update!(teacher: owner)
    other = Classroom.create!(school: school, teachers: [ owner ], grade: 2, class_number: 1)
    assignment.assignment_classrooms.create!(classroom: other)
    login
    submit
    expect(response).to have_http_status(:see_other)
    expect(Submission.last.assignment).to eq(assignment)
  end

  it "rejects other classrooms, other schools, undistributed and nonexistent assignments" do
    other = Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 2)
    foreign_school = School.create!(school_code: "OTHER1")
    foreign = Classroom.create!(school: foreign_school, teachers: [ Teacher.create!(school: foreign_school, user_id: "foreign-#{SecureRandom.hex(4)}", password: "password123") ], grade: 1, class_number: 1)
    ids = [ other, foreign, nil ].map do |target|
      item = Assignment.create!(teacher: target&.teachers&.sole || teacher, title: "範囲外", point_per_question: 5)
      item.assignment_classrooms.create!(classroom: target) if target
      item.id
    end
    login
    before_counts = counts
    (ids + [ Assignment.maximum(:id) + 100 ]).each do |id|
      post student_assignment_submission_path(id), params: { submission: { answer_file: pdf } }
      expect(response).to have_http_status(:not_found)
      expect(counts).to eq(before_counts)
    end
  end

  it "rejects a historical cross-school distribution without saving an answer PDF or registering jobs" do
    foreign_school = School.create!(school_code: "FOREIGN")
    owner = Teacher.create!(school: foreign_school, user_id: "foreign", password: "password123")
    target = Assignment.create!(teacher: owner, title: "Historical distribution", point_per_question: 5)
    target.assignment_classrooms.build(classroom: classroom).save!(validate: false)
    login
    before_counts = counts
    expect(AnswerReadingJob).not_to receive(:perform_later)
    expect(AnswerGradingJob).not_to receive(:perform_later)
    expect(QuestionGenerationJob).not_to receive(:perform_later)

    post student_assignment_submission_path(target), params: { submission: { answer_file: pdf } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(counts).to eq(before_counts)
    expect(student.submissions.where(assignment: target)).to be_empty
  end

  [ :logged_out, :teacher, :logged_out_after_login ].each do |authentication|
    it "rejects submission when #{authentication}" do
      assignment
      if authentication == :teacher
        post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
      elsif authentication == :logged_out_after_login
        login
        delete student_logout_path
      end
      before_counts = counts
      submit
      expect(response).to redirect_to(student_login_path)
      expect(counts).to eq(before_counts)
    end
  end

  it "never overwrites an existing submission even when the second file is absent" do
    login
    submit
    item = Submission.last.reload
    attributes = item.attributes
    attachment = item.answer_file.attachment.attributes
    before_counts = counts
    submit(nil)
    expect(response).to have_http_status(:see_other)
    follow_redirect!
    expect(response.body).to include("すでに提出済みです")
    expect(item.reload.attributes).to eq(attributes)
    expect(item.answer_file.attachment.reload.attributes).to eq(attachment)
    expect(counts).to eq(before_counts)
  end

  [ ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid ].each do |error_class|
    it "handles a competing submission through #{error_class}" do
      login
      item = Submission.create!(student: student, assignment: assignment, submitted_at: Time.current)
      allow_any_instance_of(Student::SubmissionsController).to receive(:existing_submission).and_return(nil, item)
      allow_any_instance_of(Submission).to receive(:save!).and_raise(error_class.new)
      before_counts = counts
      submit
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(student_assignment_path(assignment))
      expect(counts).to eq(before_counts)
      follow_redirect!
      expect(response.body).to include("すでに提出済みです")
    end
  end

  it "renders validation failures without persisting the submission or attachment" do
    login
    allow_any_instance_of(Submission).to receive(:save!).and_wrap_original do |original|
      item = original.receiver
      item.errors.add(:base, "保存できませんでした")
      raise ActiveRecord::RecordInvalid.new(item)
    end
    before_counts = counts
    submit
    expect(response).to have_http_status(422)
    expect(response.body).to include("保存できませんでした")
    expect(counts).to eq(before_counts)
    expect(document.at_css('input[type="file"]')[:value]).to be_blank
    expect(document.at_css('input[type="hidden"][name="submission[answer_file]"]')).to be_nil
  end

  it "enqueues answer reading after a successful PDF submission" do
    login

    expect {
      submit
    }.to have_enqueued_job(AnswerReadingJob).with(kind_of(Submission))

    expect(response).to have_http_status(:see_other)
  end

  [ :exception, :false, :nil ].each do |failure|
    it "preserves the answer and displays failure when reading registration returns #{failure}" do
      other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "other-password")
      other_submission = Submission.create!(assignment: assignment, student: other_student, submitted_at: Time.current)
      other_attributes = other_submission.attributes
      if failure == :exception
        allow(AnswerReadingJob).to receive(:perform_later).and_raise(StandardError, "private error details")
      else
        allow(AnswerReadingJob).to receive(:perform_later).and_return(failure == :false ? false : nil)
      end
      allow(Rails.logger).to receive(:error)
      expect(AnswerReader).not_to receive(:new)
      login
      before_counts = counts
      submit(pdf, id: other_submission.id, student_id: other_student.id, status: "completed")

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(student_assignment_path(assignment))
      item = student.submissions.find_by!(assignment: assignment)
      expect(item).to be_failed
      expect(item.answer_file).to be_attached
      expect(item.answer_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
      expect(item.submitted_at).to be_present
      expect(item.extracted_text).to be_nil
      expect(item.grading_results).to be_empty
      expect(item.score).to be_nil
      expect(counts).to eq(before_counts.map { |count| count + 1 })
      expect(other_submission.reload.attributes).to eq(other_attributes)
      expect(Rails.logger).to have_received(:error).with(/Answer reading enqueue failed: submission_id=#{item.id} /).once
      expect(Rails.logger).not_to have_received(:error).with(/private error details/)
      follow_redirect!
      expect(document.at_css("[role='alert']").text).to include("答案PDFは保存されました", "採点処理を開始できませんでした", "再提出せず")
      expect(response.body).not_to include("提出しました", "採点を待っています", "採点中です", "採点が完了しました", "private error details")
      expect(document.at_css("#grading-status").text).to include("採点失敗", "先生に確認してください")
      expect(document.at_css("#grading-status [data-controller='grading-status']")).to be_nil
      expect(document.css("form, input[type='file']")).to be_empty

      attributes = item.reload.attributes
      attachment = item.answer_file.attachment.attributes
      saved_counts = counts
      submit
      follow_redirect!
      expect(response.body).to include("すでに提出済みです", "採点失敗")
      expect(item.reload.attributes).to eq(attributes)
      expect(item.answer_file.attachment.reload.attributes).to eq(attachment)
      expect(counts).to eq(saved_counts)
      expect(AnswerReadingJob).to have_received(:perform_later).once

      post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
      get assignment_path(assignment)
      row = document.at_css("#grade-summary #grade_student_#{student.id}")
      expect(row.text).to include("採点失敗")
      expect(document.at_css("#grade_student_#{student.id} .grade-score").text).to be_empty
      get assignment_submission_path(assignment, item)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("採点失敗", "採点が完了すると")
      get answer_assignment_submission_path(assignment, item)
      expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
    end
  end

  it "does not overwrite a completed result when registration raises after the job ran" do
    login
    allow(AnswerReadingJob).to receive(:perform_later) do |item|
      Submission.find(item.id).update!(status: :completed)
      raise StandardError, "Registration result unavailable"
    end
    submit

    expect(response).to have_http_status(:see_other)
    expect(student.submissions.find_by!(assignment: assignment)).to be_completed
    expect(Submission.last.answer_file).to be_attached
    follow_redirect!
    expect(response.body).to include("提出しました")
    expect(response.body).not_to include("採点処理を開始できませんでした")
  end

  [ :upload, :handwritten ].each do |flow|
    it "uses prepared answers for #{flow} submission, reading and grading using only stubs" do
      assignment.material_file.attach(pdf)
      files = instance_double(OpenAI::Resources::Files)
      responses = instance_double(OpenAI::Resources::Responses)
      client = instance_double(OpenAI::Client, files: files, responses: responses)
      allow(AiClient).to receive(:build).and_return(client)
      allow(files).to receive(:create).and_return(double(id: "file-test"))
      allow(responses).to receive(:create) do |request|
        data = if request[:instructions].nil?
          { problems: [ { question_label: "1", question_text: "3x+2x", student_answer: "5x",
            reading_status: "readable", reading_reason: "明確" } ] }
        elsif request[:instructions].include?("添付教材")
          { questions: [ { question_label: "1", question_text: "3x+2x", correct_answer: "5x",
            grading_rule: "同類項をまとめる。", requires_work: false } ] }
        else
          question_id = JSON.parse(request.fetch(:input)).fetch("problems").sole.fetch("question_id")
          { results: [ { question_id: question_id, ai_judgment: "correct", error_point: nil, feedback: nil, review_reason: nil } ] }
        end
        instance_double(OpenAI::Models::Responses::Response, output_text: JSON.generate(data), model: "stub-model",
          status: "completed", output: [], error: nil, incomplete_details: nil)
      end
      request = QuestionGenerationRequest.select_for_distribution!(assignment)
      QuestionGenerationJob.perform_now(assignment, assignment.material_file.blob.id, request_id: request.id)
      question_id = assignment.questions.sole.id
      expect_any_instance_of(QuestionGenerator).not_to receive(:call)
      login
      perform_enqueued_jobs(only: [ AnswerReadingJob, AnswerGradingJob ]) do
        if flow == :handwritten
          draft = AnswerDraft.create!(student: student, assignment: assignment,
            material_fingerprint: AnswerDraftContext.fingerprint(assignment), page_data: [ { page_number: 1, operations: [] } ])
          post student_assignment_submission_path(assignment), params: {
            draft_version: draft.lock_version.to_s, submission: { answer_file: pdf }
          }, headers: { "X-Handwritten-Submission" => "1", "X-Draft-Context" => AnswerDraftContext.issue(student, assignment) }
        else
          submit
        end
      end

      expect(response).to have_http_status(flow == :handwritten ? :ok : :see_other)
      item = Submission.last
      expect(item).to be_completed
      expect(JSON.parse(item.extracted_text)["problems"].sole["student_answer"]).to eq("5x")
      expect(assignment.questions.sole.correct_answer).to eq("5x")
      expect(assignment.questions.sole.id).to eq(question_id)
      expect(item.grading_results.sole).to be_ai_judgment_correct
      expect(responses).to have_received(:create).exactly(3).times
      expect(files).to have_received(:create).twice
    end
  end

  it "returns a successful submission response even when AI reading fails" do
    allow(AnswerReader).to receive(:new).and_raise(StandardError, "AI failed")
    login
    perform_enqueued_jobs(only: [ AnswerReadingJob, AnswerGradingJob ]) { submit }

    expect(response).to have_http_status(:see_other)
    expect(Submission.last).to be_failed
    expect(Submission.last.grading_results).to be_empty
  end
  describe "handwritten PDF submission" do
    let(:submission_token) { SecureRandom.uuid }
    let(:draft) do
      assignment.material_file.attach(pdf)
      AnswerDraft.create!(student: student, assignment: assignment,
        material_fingerprint: AnswerDraftContext.fingerprint(assignment),
        page_data: [ { page_number: 1, operations: [] } ])
    end
    let(:headers) do
      draft
      { "X-Handwritten-Submission" => "1", "X-Draft-Context" => AnswerDraftContext.issue(student, assignment),
        "Accept" => "application/json" }
    end

    def submit_ink(version: draft.lock_version.to_s, context: headers, file: pdf)
      post student_assignment_submission_path(assignment), params: {
        draft_version: version, submission: { answer_file: file }
      }, headers: context
    end

    def submit_current_ink(version:, token: submission_token, context: headers, file: pdf)
      post student_assignment_submission_path(assignment), params: {
        draft_version: version, submission_token: token, submission: { answer_file: file }
      }, headers: context
    end

    it "submits when no draft has ever been saved and reconciles only the same PDF attempt" do
      login
      assignment.material_file.attach(pdf)
      context = { "X-Handwritten-Submission" => "1", "X-Draft-Context" => AnswerDraftContext.issue(student, assignment),
        "Accept" => "application/json" }
      expect { submit_current_ink(version: "", context: context) }.to have_enqueued_job(AnswerReadingJob).exactly(:once)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("submitted" => true, "submission_token" => submission_token)
      expect(AnswerDraft.where(student: student, assignment: assignment)).to be_empty
      expect(student.submissions.sole.answer_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
      get student_assignment_submission_path(assignment), headers: context
      expect(response.parsed_body).to include("submitted" => true, "submission_token" => submission_token)
      original = counts
      expect { submit_current_ink(version: "", context: context) }.not_to have_enqueued_job(AnswerReadingJob)
      expect(response).to have_http_status(:ok)
      expect(counts).to eq(original)
      submit_current_ink(version: "", context: context, token: SecureRandom.uuid)
      expect(response).to have_http_status(:conflict)
      expect(counts).to eq(original)
    end

    it "accepts the last confirmed draft version with unsaved ink and rejects a changed version" do
      login
      saved = draft.reload.attributes
      submit_current_ink(version: draft.lock_version.to_s)
      expect(response).to have_http_status(:ok)
      expect(draft.reload.attributes).to eq(saved)
    end

    it "rejects stale, missing and malformed confirmed versions without attaching a PDF" do
      login
      draft
      original = counts
      [ "", "1", "bogus", nil ].each do |version|
        submit_current_ink(version: version)
        expect(response).to have_http_status(:conflict)
        expect(counts).to eq(original)
      end
      draft.touch
      submit_current_ink(version: "0")
      expect(response).to have_http_status(:conflict)
      expect(counts).to eq(original)
    end

    it "rejects a draft created in another tab while an unsaved PDF is uploading" do
      login
      assignment.material_file.attach(pdf)
      context = { "X-Handwritten-Submission" => "1", "X-Draft-Context" => AnswerDraftContext.issue(student, assignment),
        "Accept" => "application/json" }
      allow_any_instance_of(ActiveStorage::Blob).to receive(:upload_without_unfurling).and_wrap_original do |original, *args|
        original.call(*args)
        AnswerDraft.create!(student: student, assignment: assignment,
          material_fingerprint: AnswerDraftContext.fingerprint(assignment), page_data: [ { page_number: 1, operations: [] } ])
      end
      before_counts = counts
      expect { submit_current_ink(version: "", context: context) }.not_to have_enqueued_job(AnswerReadingJob)
      expect(response).to have_http_status(:conflict)
      expect(counts).to eq(before_counts)
      expect(AnswerDraft.where(student: student, assignment: assignment).count).to eq(1)
    end

    it "rejects a changed material with the current-ink submission protocol" do
      login
      draft
      context = headers
      assignment.material_file.attach(pdf)
      before_counts = counts
      expect { submit_current_ink(version: "0", context: context) }.not_to have_enqueued_job(AnswerReadingJob)
      expect(response).to have_http_status(:conflict)
      expect(counts).to eq(before_counts)
    end

    it "requires a valid attempt token and preserves the draft on PDF storage failure" do
      login
      draft
      original = counts
      submit_current_ink(version: "0", token: "invalid")
      expect(response).to have_http_status(:unprocessable_content)
      expect(counts).to eq(original)
      allow_any_instance_of(ActiveStorage::Blob).to receive(:upload_without_unfurling).and_raise(IOError)
      submit_current_ink(version: "0")
      expect(response).to have_http_status(:service_unavailable)
      expect(counts).to eq(original)
      expect(draft.reload).to be_persisted
    end

    it "stores the generated PDF, retains the draft and enqueues reading only once across retries and sessions" do
      login
      token = headers
      original = draft.reload.attributes
      expect { submit_ink }.to have_enqueued_job(AnswerReadingJob).exactly(:once)
      expect(response.parsed_body).to include("submitted" => true, "location" => student_assignment_path(assignment))
      item = student.submissions.sole
      expect(item.answer_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
      expect(draft.reload.attributes).to eq(original)
      expect { submit_ink }.not_to have_enqueued_job(AnswerReadingJob)
      other = ActionDispatch::Integration::Session.new(Rails.application)
      other.post student_login_path, params: { student_session: { school_code: school.school_code,
        grade: 1, class_number: 1, attendance_number: 1, password: "student-password" } }
      expect {
        other.post student_assignment_submission_path(assignment), params: {
          draft_version: draft.lock_version.to_s, submission: { answer_file: pdf }
        }, headers: token
      }.not_to have_enqueued_job(AnswerReadingJob)
      expect(other.response.parsed_body["submitted"]).to be(true)
      expect(student.submissions.count).to eq(1)
      get student_assignment_submission_path(assignment), headers: token
      expect(response.parsed_body["submitted"]).to be(true)
      patch student_assignment_answer_draft_path(assignment), params: {
        expected_version: draft.lock_version, draft_data: { format_version: 1, pages: draft.page_data }
      }, headers: token, as: :json
      expect(response).to have_http_status(:forbidden)
      expect(draft.reload.attributes).to eq(original)
    end

    [ nil, "-1", "1", "garbage" ].each do |version|
      it "rejects missing or stale draft version #{version.inspect} without records or jobs" do
        login
        draft
        before_counts = counts
        original = draft.attributes
        expect { submit_ink(version: version) }.not_to have_enqueued_job(AnswerReadingJob)
        expect(response).to have_http_status(:conflict)
        expect(counts).to eq(before_counts)
        expect(draft.reload.attributes).to eq(original)
      end
    end

    it "checks the draft version again after the PDF upload" do
      login
      draft
      allow_any_instance_of(ActiveStorage::Blob).to receive(:upload_without_unfurling).and_wrap_original do |original, *args|
        original.call(*args)
        AnswerDraft.find(draft.id).touch
      end
      token = headers
      before_counts = counts
      submit_ink(version: "0", context: token)
      expect(response).to have_http_status(:conflict)
      expect(counts).to eq(before_counts)
      expect(draft.reload.lock_version).to eq(1)
    end

    it "rejects a changed source PDF, a different student's context and deleted assignments" do
      login
      token = headers
      other = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
      submit_ink(context: token.merge("X-Draft-Context" => AnswerDraftContext.issue(other, assignment)))
      expect(response).to have_http_status(:conflict)
      assignment.material_file.attach(pdf)
      submit_ink(context: token)
      expect(response).to have_http_status(:conflict)
      draft.destroy!
      assignment.assignment_classrooms.each(&:destroy!)
      assignment.destroy!
      post student_assignment_submission_path(assignment.id), headers: token
      expect(response).to have_http_status(:not_found)
      expect(Submission.count).to eq(0)
    end

    it "retains the draft and creates no submission when storage upload fails" do
      login
      draft
      before_counts = counts
      allow_any_instance_of(ActiveStorage::Blob).to receive(:upload_without_unfurling).and_raise(IOError, "storage failed")
      submit_ink
      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body).to include("error" => "storage_unavailable", "message" => a_string_including("答案PDFを保存できませんでした"))
      expect(response.body).not_to include("storage failed")
      expect(counts).to eq(before_counts)
      expect(draft.reload).to be_persisted
      expect(enqueued_jobs.none? { |job| job[:job] == AnswerReadingJob }).to be(true)
    end

    it "removes the unattached upload and keeps the draft if Submission validation fails" do
      login
      draft
      before_counts = counts
      original = draft.attributes
      allow_any_instance_of(Submission).to receive(:save!).and_raise(ActiveRecord::RecordInvalid)
      expect { submit_ink }.not_to have_enqueued_job(AnswerReadingJob)
      expect(response).to have_http_status(:unprocessable_content)
      expect(counts).to eq(before_counts)
      expect(draft.reload.attributes).to eq(original)
    end

    it "rejects malformed PDFs without changing the draft" do
      login
      draft
      before_counts = counts
      submit_ink(file: Rack::Test::UploadedFile.new(StringIO.new("bad"), "application/pdf", original_filename: "answer.pdf"))
      expect(response).to have_http_status(:unprocessable_entity)
      expect(counts).to eq(before_counts)
      expect(draft.reload).to be_persisted
    end

    it "rejects an oversized generated PDF and preserves the draft without enqueueing a job" do
      login
      token = headers
      original = draft.attributes
      before_counts = counts
      header = "%PDF-1.4\n"
      contents = header + ("0" * (Student::SubmissionsController::MAX_PDF_BYTES + 1 - header.bytesize))
      upload = Rack::Test::UploadedFile.new(StringIO.new(contents), "application/pdf", original_filename: "answer.pdf")

      expect do
        post student_assignment_submission_path(assignment), params: {
          draft_version: draft.lock_version.to_s, submission: { answer_file: upload }
        }, headers: token
      end.not_to have_enqueued_job(AnswerReadingJob)
      expect(response).to have_http_status(:content_too_large)
      expect(response.parsed_body).to eq("error" => "file_too_large")
      expect(counts).to eq(before_counts)
      expect(draft.reload.attributes).to eq(original)
    end

    it "preserves a committed answer when enqueueing fails and does not retry the job on POST retry" do
      login
      allow(AnswerReadingJob).to receive(:perform_later).and_return(false)
      submit_ink
      expect(response.parsed_body).to include("submitted" => true)
      expect(response.parsed_body["alert"]).to include("採点処理を開始できませんでした")
      expect(student.submissions.sole).to be_failed
      submit_ink
      expect(AnswerReadingJob).to have_received(:perform_later).once
    end

    it "keeps authentication and CSRF protection on handwritten submission" do
      token = headers
      submit_ink(context: token)
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["Location"]).to be_nil
      login
      previous = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      submit_ink(context: token)
      expect(response).to have_http_status(:unprocessable_content)
      expect(Submission.count).to eq(0)
    ensure
      ActionController::Base.allow_forgery_protection = previous unless previous.nil?
    end

    it "rejects another student in the same classroom using the owner's submission context" do
      login
      token = headers
      other = Student.create!(classroom: classroom, attendance_number: 2, password: "other-password")
      other_client = ActionDispatch::Integration::Session.new(Rails.application)
      other_client.post student_login_path, params: { student_session: { school_code: school.school_code,
        grade: classroom.grade, class_number: classroom.class_number,
        attendance_number: other.attendance_number, password: "other-password" } }
      before_counts = counts

      other_client.get student_assignment_submission_path(assignment), headers: token
      expect(other_client.response).to have_http_status(:conflict)
      other_client.post student_assignment_submission_path(assignment), params: {
        draft_version: draft.lock_version.to_s, submission: { answer_file: pdf }
      }, headers: token
      expect(other_client.response).to have_http_status(:conflict)
      expect(counts).to eq(before_counts)
      expect(draft.reload.student).to eq(student)
      expect(other.submissions).to be_empty
    end

    it "does not let teacher or admin sessions use student draft and submission APIs" do
      token = headers
      admin = Admin.create!(school: school, user_id: "ink-admin", password: "admin-password")
      before_counts = counts
      [
        [ login_path, { session: { user_id: teacher.user_id, password: "password123" } } ],
        [ admin_login_path, { admin_session: { user_id: admin.user_id, password: "admin-password" } } ]
      ].each do |path, credentials|
        client = ActionDispatch::Integration::Session.new(Rails.application)
        client.post path, params: credentials
        client.get student_assignment_answer_draft_path(assignment), headers: token
        expect(client.response).to have_http_status(:unauthorized)
        client.patch student_assignment_answer_draft_path(assignment), params: {
          expected_version: draft.lock_version, draft_data: { format_version: 1, pages: draft.page_data }
        }, headers: token, as: :json
        expect(client.response).to have_http_status(:unauthorized)
        client.get student_assignment_submission_path(assignment), headers: token
        expect(client.response).to have_http_status(:unauthorized)
        expect(client.response.headers["Location"]).to be_nil
        client.post student_assignment_submission_path(assignment), params: {
          draft_version: draft.lock_version.to_s, submission: { answer_file: pdf }
        }, headers: token
        expect(client.response).to have_http_status(:unauthorized)
        expect(client.response.headers["Location"]).to be_nil
      end
      expect(counts).to eq(before_counts)
      expect(draft.reload).to be_persisted
      expect(student.submissions).to be_empty
    end

    [ :classroom, :school ].each do |scope|
      it "rejects handwritten submission and status checks outside the student's #{scope}" do
        login
        token = headers
        if scope == :classroom
          assignment.assignment_classrooms.each(&:destroy!)
        else
          foreign = School.create!(school_code: "INKFOREIGN")
          assignment.update!(teacher: Teacher.create!(school: foreign, user_id: "inkforeign", password: "password123"))
        end
        submit_ink(context: token)
        expect(response).to have_http_status(:not_found)
        get student_assignment_submission_path(assignment), headers: token
        expect(response).to have_http_status(:not_found)
        expect(Submission.count).to eq(0)
        expect(draft.reload).to be_persisted
      end
    end
  end
end
