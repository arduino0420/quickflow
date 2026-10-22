require "rails_helper"

RSpec.describe "Authentication branding and role-specific home links", type: :request do
  let(:school) { School.create!(school_code: "BRAND") }
  let(:teacher) { Teacher.create!(school: school, user_id: "brand-teacher", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }

  def document
    Nokogiri::HTML(response.body)
  end

  it "shows prominent branding without registration guidance and masked passwords without public signup" do
    [ login_path, student_login_path ].each do |path|
      get path
      expect(document.at_css(".app-header--auth .app-brand").text).to eq("QuickFlow")
      expect(document.at_css("a.app-brand")).to be_nil
      expect(document.at_css(".account-registration-help")).to be_nil
      expect(response.body).not_to include("アカウントの登録について", "新規登録は", "運用担当者が登録", "所属を確認した先生")
      expect(document.at_css("input[type='password']")[:autocomplete]).to eq("current-password")
      expect(response.body).not_to include("もっとスムーズに", "役割を選択")
    end
    expect { Rails.application.routes.recognize_path("/signup", method: :post) }.to raise_error(ActionController::RoutingError)
    expect { Rails.application.routes.recognize_path("/student/signup", method: :post) }.to raise_error(ActionController::RoutingError)
  end

  it "links the teacher logo to assignments and switches it when a student logs in" do
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
    follow_redirect!
    expect(document.at_css("a.app-brand")[:href]).to eq(assignments_path)
    post student_login_path, params: { student_session: {
      school_code: school.school_code, grade: 1, class_number: 1, attendance_number: student.attendance_number, password: "password123"
    } }
    follow_redirect!
    expect(document.at_css("a.app-brand")[:href]).to eq(student_assignments_path)
    get assignments_path
    expect(response).to redirect_to(login_path)
    delete student_logout_path
    follow_redirect!
    expect(document.at_css("a.app-brand")).to be_nil
  end
end
