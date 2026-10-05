require "rails_helper"

RSpec.describe "Teacher sessions", type: :request do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "student-password") }

  def student_login
    post student_login_path, params: { student_session: {
      school_code: school.school_code, grade: classroom.grade, class_number: classroom.class_number,
      attendance_number: student.attendance_number, password: "student-password"
    } }
  end

  def login
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
  end

  def expect_login_form
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('form[action="/login"][method="post"]')).to be_present
    expect(document.at_css('input[name="session[user_id]"]')).to be_present
    expect(document.at_css('input[name="session[password]"][type="password"]')).to be_present
    expect(document.at_css('form[action="/logout"]')).to be_nil
  end

  it "shows the login form when logged out" do
    get login_path

    expect(response).to have_http_status(:ok)
    expect_login_form
  end

  it "logs in and retains the teacher across subsequent requests" do
    login

    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(login_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("ログイン中のユーザーID: #{teacher.user_id}")
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('form[action="/login"]')).to be_nil
    expect(document.at_css('form[action="/logout"] input[name="_method"]')[:value]).to eq("delete")

    get login_path
    expect(response.body).to include("ログイン中のユーザーID: #{teacher.user_id}")
  end

  [
    { user_id: "unknown", password: "password123" },
    { user_id: "teacher1", password: "wrong-password" },
    { user_id: "", password: "password123" },
    { user_id: "teacher1", password: "" },
    { user_id: "", password: "" }
  ].each do |credentials|
    it "rejects invalid credentials #{credentials.inspect}" do
      teacher
      post login_path, params: { session: credentials }

      expect(response).to have_http_status(422)
      expect(response.body).to include("ユーザーIDまたはパスワードが正しくありません。")
      expect_login_form
      password_input = Nokogiri::HTML(response.body).at_css('input[name="session[password]"]')
      expect(password_input[:value]).to be_blank

      get login_path
      expect_login_form
      expect(response.body).not_to include("ユーザーIDまたはパスワードが正しくありません。")
    end
  end

  it "logs out and clears authentication for subsequent requests" do
    login
    delete logout_path

    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(login_path)
    follow_redirect!
    expect_login_form

    get login_path
    expect_login_form
  end

  it "allows logout without a logged-in teacher" do
    delete logout_path

    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(login_path)
    follow_redirect!
    expect_login_form
  end

  it "treats a session for a deleted teacher as logged out" do
    login
    teacher.destroy!

    get login_path

    expect(response).to have_http_status(:ok)
    expect_login_form
  end

  it "replaces a student session after successful teacher authentication" do
    student_login
    get login_path
    expect_login_form
    get student_login_path
    expect(response.body).to include("ログイン中: 1年 1組 出席番号 1")

    login
    follow_redirect!
    expect(response.body).to include("ログイン中のユーザーID: #{teacher.user_id}")
    get student_login_path
    expect(response.body).not_to include("ログイン中:")
    expect(Nokogiri::HTML(response.body).at_css('form[action="/student/login"]')).to be_present
  end

  it "retains a student session after failed teacher authentication" do
    student_login
    post login_path, params: { session: { user_id: teacher.user_id, password: "wrong-password" } }

    expect(response).to have_http_status(422)
    get student_login_path
    expect(response.body).to include("ログイン中: 1年 1組 出席番号 1")
  end

  it "clears a student session when using teacher logout" do
    student_login
    delete logout_path

    get student_login_path
    expect(response.body).not_to include("ログイン中:")
  end
end
