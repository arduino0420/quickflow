require "rails_helper"

RSpec.describe "Student PDF previews", type: :request do
  let(:school) { School.create!(school_code: "PDF001") }
  let(:teacher) { Teacher.create!(school: school, user_id: "pdf-teacher", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  let(:assignment) do
    Assignment.create!(teacher: teacher, title: "PDF試作", point_per_question: 5).tap do |item|
      item.assignment_classrooms.create!(classroom: classroom)
      item.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")),
        filename: "material.pdf", content_type: "application/pdf")
    end
  end

  def login
    student
    post student_login_path, params: { student_session: {
      school_code: school.school_code, grade: 1, class_number: 1,
      attendance_number: 1, password: "password123"
    } }
  end

  it "renders a separate preview wired to the authenticated material URL without submitting" do
    login
    expect(AnswerReadingJob).not_to receive(:perform_later)
    expect { get student_assignment_pdf_preview_path(assignment) }.not_to change(Submission, :count)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    document = Nokogiri::HTML(response.body)
    preview = document.at_css('[data-controller="pdf-preview"]')
    expect(preview["data-pdf-preview-url-value"]).to eq(material_student_assignment_path(assignment))
    expect(preview["data-pdf-preview-assets-url-value"]).to eq("/vendor/pdfjs/6.4.299/")
    expect(preview.text).to include("問題を読み込んでいます")
    expect(document.css("canvas").size).to eq(2)
    expect(document.at_css('canvas[data-pdf-preview-target="ink"]')).to be_present
    expect(document.at_css('button[data-pdf-preview-tool-param="pen"]')["aria-pressed"]).to eq("true")
    expect(document.at_css('button[data-pdf-preview-tool-param="eraser"]')["aria-pressed"]).to eq("false")
    expect(response.body).to include("書いた内容は保存されません")
    expect(document.css('input[type="file"], input[type="submit"]')).to be_empty

    get material_student_assignment_path(assignment)
    expect(response.media_type).to eq("application/pdf")
    expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
  end

  it "requires student login" do
    get student_assignment_pdf_preview_path(assignment)
    expect(response).to redirect_to(student_login_path)
  end

  it "does not accept a teacher session" do
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
    get student_assignment_pdf_preview_path(assignment)
    expect(response).to redirect_to(student_login_path)
  end

  it "rejects assignments outside the student's classroom or school" do
    assignment
    other_class = Classroom.create!(school: school, grade: 1, class_number: 2)
    other = Assignment.create!(teacher: teacher, title: "別クラス", point_per_question: 5)
    other.assignment_classrooms.create!(classroom: other_class)
    foreign_school = School.create!(school_code: "PDF002")
    foreign_teacher = Teacher.create!(school: foreign_school, user_id: "foreign-pdf", password: "password123")
    foreign_class = Classroom.create!(school: foreign_school, grade: 1, class_number: 1)
    foreign = Assignment.create!(teacher: foreign_teacher, title: "他校", point_per_question: 5)
    foreign.assignment_classrooms.create!(classroom: foreign_class)
    login
    [ other, foreign ].each do |item|
      get student_assignment_pdf_preview_path(item)
      expect(response).to have_http_status(:not_found)
      get material_student_assignment_path(item)
      expect(response).to have_http_status(:not_found)
    end
  end

  it "rejects even a historical cross-school distribution" do
    assignment
    foreign_school = School.create!(school_code: "PDF003")
    foreign_teacher = Teacher.create!(school: foreign_school, user_id: "legacy-pdf", password: "password123")
    foreign = Assignment.create!(teacher: foreign_teacher, title: "不整合", point_per_question: 5)
    foreign.assignment_classrooms.build(classroom: classroom).save!(validate: false)
    login
    get student_assignment_pdf_preview_path(foreign)
    expect(response).to have_http_status(:not_found)
  end

  it "keeps the existing upload screen and its links unchanged" do
    login
    get student_assignment_path(assignment)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('input[type="file"]')["name"]).to eq("submission[answer_file]")
    expect(document.at_css('form input[type="file"]').ancestors("form").first["action"])
      .to eq(student_assignment_submission_path(assignment))
    expect(document.at_css('[data-controller="pdf-preview"]')).to be_nil
  end
end
