require "rails_helper"

RSpec.describe "Minimal footer", type: :request do
  let(:school) { School.create!(school_code: "FOOTER") }
  let(:teacher) { Teacher.create!(school: school, user_id: "footer-teacher", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  let(:admin) { Admin.create!(school: school, user_id: "footer-admin", password: "password123") }

  def expect_footer
    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.css("body.app-shell > main + footer.app-footer").size).to eq(1)
    expect(document.at_css("footer").text).to eq("© QuickFlow")
    expect(document.css("footer a, footer button")).to be_empty
  end

  it "includes the same minimal footer on home and all login pages" do
    [ root_path, login_path, student_login_path, admin_login_path ].each do |path|
      get path
      expect_footer
    end
  end

  it "includes it in authenticated teacher and admin screens" do
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
    get assignments_path
    expect_footer
    post admin_login_path, params: { admin_session: { user_id: admin.user_id, password: "password123" } }
    [ admin_root_path, admin_teachers_path, admin_students_path ].each do |path|
      get path
      expect_footer
    end
  end

  it "includes it in student screens but preserves the handwriting workspace without the footer or flex shell" do
    student
    assignment = Assignment.create!(teacher: teacher, title: "フッター確認", point_per_question: 5)
    assignment.assignment_classrooms.create!(classroom: classroom)
    post student_login_path, params: { student_session: {
      school_code: school.school_code, grade: 1, class_number: 1, attendance_number: 1, password: "password123"
    } }
    [ student_assignments_path, student_assignment_path(assignment) ].each do |path|
      get path
      expect_footer
    end
    get student_assignment_pdf_preview_path(assignment)
    expect(response).to have_http_status(:ok)
    document = Nokogiri::HTML(response.body)
    expect(document.css("footer, body.app-shell")).to be_empty
    expect(document.at_css("body > header + main .pdf-preview")).to be_present
    expect(document.css("canvas").size).to eq(2)
    expect(document.at_css('[data-pdf-preview-target="submit"]').text).to eq("提出する")
    get student_assignments_path
    expect_footer
  end
end
