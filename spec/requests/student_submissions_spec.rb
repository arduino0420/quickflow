require "rails_helper"

RSpec.describe "Student submissions", type: :request do
  include ActiveJob::TestHelper
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
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
    expect(response.body).to include("提出しました", "提出済み", "material.pdf", item.submitted_at.strftime("%Y/%m/%d %H:%M"))
    expect(document.css("form, input")).to be_empty
    expect(document.css("a").map { |link| link[:href] }).to eq([ student_assignments_path ])
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

  it "allows another teacher's assignment distributed to multiple classes including the student's" do
    owner = Teacher.create!(school: school, user_id: "teacher2", password: "password123")
    assignment.update!(teacher: owner)
    other = Classroom.create!(school: school, teacher: owner, grade: 2, class_number: 1)
    assignment.assignment_classrooms.create!(classroom: other)
    login
    submit
    expect(response).to have_http_status(:see_other)
    expect(Submission.last.assignment).to eq(assignment)
  end

  it "rejects other classrooms, other schools, undistributed and nonexistent assignments" do
    other = Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 2)
    foreign_school = School.create!(school_code: "OTHER1")
    foreign = Classroom.create!(school: foreign_school, teacher: teacher, grade: 1, class_number: 1)
    ids = [ other, foreign, nil ].map do |target|
      item = Assignment.create!(teacher: teacher, title: "範囲外", point_per_question: 5)
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

  it "uses answers prepared before submission for reading and grading using only stubs" do
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
        status: "completed", output: [])
    end
    QuestionGenerationJob.perform_now(assignment, assignment.material_file.blob.id)
    question_id = assignment.questions.sole.id
    expect_any_instance_of(QuestionGenerator).not_to receive(:call)
    login
    perform_enqueued_jobs(only: [ AnswerReadingJob, AnswerGradingJob ]) { submit }

    expect(response).to have_http_status(:see_other)
    item = Submission.last
    expect(item).to be_completed
    expect(JSON.parse(item.extracted_text)["problems"].sole["student_answer"]).to eq("5x")
    expect(assignment.questions.sole.correct_answer).to eq("5x")
    expect(assignment.questions.sole.id).to eq(question_id)
    expect(item.grading_results.sole).to be_ai_judgment_correct
    expect(responses).to have_received(:create).exactly(3).times
    expect(files).to have_received(:create).twice
  end

  it "returns a successful submission response even when AI reading fails" do
    allow(AnswerReader).to receive(:new).and_raise(StandardError, "AI failed")
    login
    perform_enqueued_jobs(only: [ AnswerReadingJob, AnswerGradingJob ]) { submit }

    expect(response).to have_http_status(:see_other)
    expect(Submission.last).to be_failed
    expect(Submission.last.grading_results).to be_empty
  end
end
