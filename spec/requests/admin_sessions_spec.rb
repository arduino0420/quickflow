require "rails_helper"

RSpec.describe "Admin sessions", type: :request do
  let(:school) { School.create!(school_code: "ADMINLOGIN") }
  let(:admin) { Admin.create!(school: school, user_id: "admin-login", password: "synthetic-admin-password") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher-login", password: "synthetic-teacher-password") }
  let(:classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "synthetic-student-password") }

  def document
    Nokogiri::HTML(response.body)
  end

  def admin_login
    post admin_login_path, params: { admin_session: { user_id: admin.user_id, password: "synthetic-admin-password" } }
  end

  def teacher_login
    post login_path, params: { session: { user_id: teacher.user_id, password: "synthetic-teacher-password" } }
  end

  def student_login
    post student_login_path, params: { student_session: { school_code: school.school_code, grade: 1, class_number: 1,
      attendance_number: student.attendance_number, password: "synthetic-student-password" } }
  end

  it "shows only admin ID and masked password inputs without public signup" do
    get admin_login_path

    expect(response).to have_http_status(:ok)
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    expect(document.at_css("h1").text).to eq("管理者ログイン")
    expect(document.at_css("form[action='/admin/login'][method='post']")).to be_present
    expect(document.at_css("input[name='admin_session[user_id]']")[:autocomplete]).to eq("username")
    expect(document.at_css("input[name='admin_session[user_id]']")[:placeholder]).to eq("例：admin01")
    field = document.at_css("input[name='admin_session[password]']")
    expect(field[:type]).to eq("password")
    expect(field[:autocomplete]).to eq("current-password")
    expect(field[:value]).to be_blank
    expect { Rails.application.routes.recognize_path("/admin/signup", method: :post) }.to raise_error(ActionController::RoutingError)
  end

  it "authenticates an admin and retains only the admin identity" do
    admin_login

    expect(response).to redirect_to(admin_root_path)
    expect(response).to have_http_status(:see_other)
    expect(response.request.session[:admin_id]).to eq(admin.id)
    expect(response.request.session[:teacher_id]).to be_nil
    expect(response.request.session[:student_id]).to be_nil
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(document.at_css("h1").text).to eq("管理者トップ")
    expect(document.at_css("a.app-brand")[:href]).to eq(admin_root_path)
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    get admin_login_path
    expect(response).to redirect_to(admin_root_path)
  end

  [ :teacher, :student ].each do |role|
    it "regenerates the #{role} session and removes its identity on successful admin login" do
      public_send("#{role}_login")
      old_id = response.request.session.id.to_s
      expect(old_id).to be_present

      admin_login

      expect(response.request.session.id.to_s).not_to eq(old_id)
      expect(response.request.session[:admin_id]).to eq(admin.id)
      expect(response.request.session[:teacher_id]).to be_nil
      expect(response.request.session[:student_id]).to be_nil
    end

    it "rejects an authenticated #{role} from the admin dashboard" do
      public_send("#{role}_login")
      get admin_root_path

      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(admin_login_path)
      expect(response.request.session[:admin_id]).to be_nil
    end

    it "clears admin authentication when a real #{role} subsequently logs in" do
      admin_login
      public_send("#{role}_login")

      expect(response).to have_http_status(:see_other)
      expect(response.request.session[:admin_id]).to be_nil
      get admin_root_path
      expect(response).to redirect_to(admin_login_path)
    end
  end

  it "rejects an anonymous request even when admin and school IDs are forged" do
    get admin_root_path, params: { admin_id: admin.id, school_id: school.id }

    expect(response).to redirect_to(admin_login_path)
    expect(response.request.session[:admin_id]).to be_nil
  end

  it "uses the same error for unknown IDs, wrong passwords and blank credentials" do
    admin
    messages = []
    [ [ "unknown", "wrong-secret" ], [ admin.user_id, "wrong-secret" ], [ "", "" ], [ admin.user_id, "" ] ].each do |id, password|
      post admin_login_path, params: { admin_session: { user_id: id, password: password } }

      expect(response).to have_http_status(422)
      messages << document.at_css("[role='alert']").text
      expect(document.at_css("input[name='admin_session[password]']")[:value]).to be_blank
      expect(response.body).not_to include("wrong-secret")
      expect(response.request.session[:admin_id]).to be_nil
      get admin_login_path
      expect(document.at_css("[role='alert']")).to be_nil
    end
    expect(messages.uniq).to eq([ "管理者IDまたはパスワードが正しくありません。" ])
  end

  [ :teacher, :student ].each do |role|
    it "rejects #{role} credentials on admin login even with a colliding numeric ID" do
      actor = public_send(role)
      Admin.create!(id: actor.id, school: school, user_id: "unrelated-admin", password: "another-admin-password")
      post admin_login_path, params: { admin_session: { user_id: role == :teacher ? actor.user_id : actor.attendance_number.to_s,
        password: "synthetic-#{role}-password", admin_id: actor.id } }

      expect(response).to have_http_status(422)
      expect(response.request.session[:admin_id]).to be_nil
    end
  end

  it "does not authenticate admin credentials through teacher login or grant teacher/student access" do
    admin_login
    post login_path, params: { session: { user_id: admin.user_id, password: "synthetic-admin-password" } }

    expect(response).to have_http_status(422)
    expect(response.request.session[:teacher_id]).to be_nil
    get assignments_path
    expect(response).to redirect_to(login_path)
    get student_assignments_path
    expect(response).to redirect_to(student_login_path)
  end

  it "keeps same-text admin and teacher IDs as separate credentials" do
    teacher = Teacher.create!(school: school, user_id: admin.user_id, password: "synthetic-teacher-password")
    post admin_login_path, params: { admin_session: { user_id: teacher.user_id, password: "synthetic-teacher-password" } }
    expect(response).to have_http_status(422)
    admin_login
    expect(response).to redirect_to(admin_root_path)
  end

  it "does not switch schools using request parameters" do
    foreign_school = School.create!(school_code: "FOREIGNADMIN")
    foreign_admin = Admin.create!(school: foreign_school, user_id: "foreign-admin", password: "synthetic-foreign-password")
    post admin_login_path, params: { admin_session: { user_id: admin.user_id, password: "synthetic-admin-password",
      school_id: foreign_school.id, admin_id: foreign_admin.id } }
    get admin_root_path, params: { school_id: foreign_school.id, admin_id: foreign_admin.id }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(school.school_code)
    expect(response.body).not_to include(foreign_school.school_code, foreign_admin.user_id)
    expect(response.request.session[:admin_id]).to eq(admin.id)
    expect(admin.reload.school).to eq(school)
  end

  it "logs out with DELETE and removes dashboard access" do
    admin_login
    follow_redirect!
    form = document.at_css("form[action='/admin/logout'][method='post']")
    expect(form.at_css("input[name='_method']")[:value]).to eq("delete")
    delete admin_logout_path

    expect(response).to redirect_to(admin_login_path)
    expect(response).to have_http_status(:see_other)
    expect(response.request.session[:admin_id]).to be_nil
    get admin_root_path
    expect(response).to redirect_to(admin_login_path)
  end

  it "does not provide a GET logout endpoint" do
    admin_login
    get admin_logout_path

    expect(response).to have_http_status(:not_found)
    get admin_root_path
    expect(response).to have_http_status(:ok)
  end

  it "treats a deleted admin session as logged out" do
    admin_login
    admin.destroy!
    get admin_root_path

    expect(response).to redirect_to(admin_login_path)
  end

  it "does not update account or classroom data during login, viewing and logout" do
    records = [ admin, teacher, classroom, student, classroom.teacher_classrooms.sole ]
    original = records.map { |record| record.reload.attributes }
    admin_login
    get admin_root_path
    delete admin_logout_path

    expect(records.map { |record| record.reload.attributes }).to eq(original)
  end

  [ nil, "invalid", [ "invalid" ] ].each do |input|
    it "rejects malformed login input #{input.inspect} without setting an admin session" do
      post admin_login_path, params: { admin_session: input }

      expect(response).to have_http_status(:bad_request)
      expect(response.request.session[:admin_id]).to be_nil
    end
  end

  it "does not output an entered password in response or application logs" do
    admin
    buffer = StringIO.new
    owners = [ Rails, ActionController::Base, ActiveRecord::Base ]
    originals = owners.to_h { |owner| [ owner, owner.logger ] }
    logger = ActiveSupport::Logger.new(buffer)
    begin
      owners.each { |owner| owner.logger = logger }
      post admin_login_path, params: { admin_session: { user_id: admin.user_id, password: "private-entered-password" } }
    ensure
      originals.each { |owner, original| owner.logger = original }
    end

    expect(response).to have_http_status(422)
    expect(response.body).not_to include("private-entered-password", admin.password_digest)
    expect(buffer.string).not_to include("private-entered-password", admin.password_digest)
  end

  it "requires valid CSRF tokens for login and logout" do
    original_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get admin_login_path
    token = document.at_css("input[name='authenticity_token']")[:value]
    credentials = { user_id: admin.user_id, password: "synthetic-admin-password" }

    post admin_login_path, params: { admin_session: credentials }
    expect(response).to have_http_status(422)
    expect(response.request.session[:admin_id]).to be_nil
    post admin_login_path, params: { authenticity_token: token, admin_session: credentials }
    expect(response).to redirect_to(admin_root_path)
    follow_redirect!
    token = document.at_css("form[action='/admin/logout'] input[name='authenticity_token']")[:value]
    expect(token).to be_present

    delete admin_logout_path
    expect(response).to have_http_status(422)
    get admin_root_path
    expect(response).to have_http_status(:ok)
    delete admin_logout_path, params: { authenticity_token: token }
    expect(response).to redirect_to(admin_login_path)
    get admin_root_path
    expect(response).to redirect_to(admin_login_path)
  ensure
    ActionController::Base.allow_forgery_protection = original_protection
  end
end
