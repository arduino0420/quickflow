require "rails_helper"

RSpec.describe "Student sessions", type: :request do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "teacher-password") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 2) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 3, password: "student-password") }
  let(:credentials) do
    { school_code: school.school_code, grade: classroom.grade, class_number: classroom.class_number,
      attendance_number: student.attendance_number, password: "student-password" }
  end

  def login
    post student_login_path, params: { student_session: credentials }
  end

  def expect_login_form
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('form[action="/student/login"][method="post"]')).to be_present
    %w[school_code grade class_number attendance_number password].each do |field|
      expect(document.at_css("input[name='student_session[#{field}]']")).to be_present
    end
    expect(document.at_css('input[name="student_session[password]"][type="password"]')).to be_present
    expect(document.at_css('form[action="/student/logout"]')).to be_nil
  end

  def expect_logged_in
    expect(response.body).to include("ログイン中: 1年 2組 出席番号 3")
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('form[action="/student/login"]')).to be_nil
    expect(document.at_css('form[action="/student/logout"] input[name="_method"]')[:value]).to eq("delete")
  end

  it "shows the login form when logged out" do
    get student_login_path

    expect(response).to have_http_status(:ok)
    expect_login_form
  end

  it "logs in and retains the student across subsequent requests" do
    login

    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(student_assignments_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("配信された小テスト")

    get student_login_path
    expect_logged_in
  end

  {
    school_code: "UNKNOWN", grade: 2, class_number: 3, attendance_number: 4, password: "wrong-password"
  }.each do |field, value|
    it "rejects an incorrect #{field}" do
      post student_login_path, params: { student_session: credentials.merge(field => value) }

      expect(response).to have_http_status(422)
      expect(response.body).to include("ログイン情報またはパスワードが正しくありません。")
      expect_login_form
      expect(Nokogiri::HTML(response.body).at_css('input[name="student_session[password]"]')[:value]).to be_blank

      get student_login_path
      expect_login_form
      expect(response.body).not_to include("ログイン情報またはパスワードが正しくありません。")
    end
  end

  %i[school_code grade class_number attendance_number password].each do |field|
    it "rejects a blank #{field}" do
      post student_login_path, params: { student_session: credentials.merge(field => "") }

      expect(response).to have_http_status(422)
      expect(response.body).to include("ログイン情報またはパスワードが正しくありません。")
      expect_login_form
    end
  end

  it "selects the student's school, grade and classroom despite matching attendance numbers" do
    student
    other_school = School.create!(school_code: "OTHER1")
    [
      { school: other_school, grade: 1, class_number: 2 },
      { school: school, grade: 2, class_number: 2 },
      { school: school, grade: 1, class_number: 3 }
    ].each do |attributes|
      other_classroom = Classroom.create!(attributes.merge(teacher: teacher))
      Student.create!(classroom: other_classroom, attendance_number: 3, password: "student-password")
    end

    login
    follow_redirect!
    expect(response.body).to include("配信された小テスト")
    get student_login_path
    expect_logged_in
    expect(response.request.session[:student_id]).to eq(student.id)
  end

  it "uses the classroom's school rather than the teacher's school" do
    other_school = School.create!(school_code: "OTHER1")
    classroom.update!(school: other_school)
    login_credentials = credentials.merge(school_code: other_school.school_code)

    post student_login_path, params: { student_session: login_credentials }

    expect(response).to have_http_status(:see_other)
    follow_redirect!
    expect(response.body).to include("配信された小テスト")
    get student_login_path
    expect_logged_in
  end

  it "logs out and clears authentication for subsequent requests" do
    login
    delete student_logout_path

    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(student_login_path)
    follow_redirect!
    expect_login_form
    get student_login_path
    expect_login_form
  end

  it "allows logout without a logged-in student" do
    delete student_logout_path

    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(student_login_path)
    follow_redirect!
    expect_login_form
  end

  it "treats a session for a deleted student as logged out" do
    login
    student.destroy!

    get student_login_path

    expect(response).to have_http_status(:ok)
    expect_login_form
  end

  it "replaces a teacher session after successful student authentication" do
    post login_path, params: { session: { user_id: teacher.user_id, password: "teacher-password" } }
    get student_login_path
    expect_login_form
    get login_path
    expect(response.body).to include("ログイン中のユーザーID: #{teacher.user_id}")

    login
    follow_redirect!
    expect(response.body).to include("配信された小テスト")
    get student_login_path
    expect_logged_in
    get login_path
    expect(response.body).not_to include("ログイン中のユーザーID:")
    expect(Nokogiri::HTML(response.body).at_css('form[action="/login"]')).to be_present
  end

  it "retains a teacher session after failed student authentication" do
    post login_path, params: { session: { user_id: teacher.user_id, password: "teacher-password" } }
    post student_login_path, params: { student_session: credentials.merge(password: "wrong-password") }

    expect(response).to have_http_status(422)
    get login_path
    expect(response.body).to include("ログイン中のユーザーID: #{teacher.user_id}")
  end

  it "clears a teacher session when using student logout" do
    post login_path, params: { session: { user_id: teacher.user_id, password: "teacher-password" } }
    delete student_logout_path

    get login_path
    expect(response.body).not_to include("ログイン中のユーザーID:")
  end
end
