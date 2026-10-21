require "rails_helper"

RSpec.describe "Admin account management", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:school) { School.create!(school_code: "MANAGE") }
  let(:admin) { Admin.create!(school: school, user_id: "manage-admin", password: "admin-secret") }
  let(:room) { Classroom.create!(school: school, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: room, attendance_number: 1, password: "original-secret") }
  let(:foreign_school) { School.create!(school_code: "FOREIGNMANAGE") }
  let(:foreign_room) { Classroom.create!(school: foreign_school, grade: 6, class_number: 15) }
  let(:foreign_student) { Student.create!(classroom: foreign_room, attendance_number: 40, password: "foreign-secret") }

  def login(account = admin, password = "admin-secret")
    post admin_login_path, params: { admin_session: { user_id: account.user_id, password: password } }
    expect(response).to redirect_to(admin_root_path)
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def token
    document.at_css('input[name="edit_token"]')["value"]
  end

  def password_form(target = student)
    get edit_admin_student_password_reset_path(target)
    expect(response).to have_http_status(:ok)
    token
  end

  def reset_password(password: "739162840517294", admin_password: "admin-secret", target: student, edit_token: password_form(target), **extra)
    patch admin_student_password_reset_path(target), params: { edit_token: edit_token, confirmed: "1", admin_password: admin_password,
      student: { password: password, password_confirmation: password }, **extra }
  end

  def preview_change(**attributes)
    get edit_admin_student_path(student)
    post confirm_update_admin_student_path(student), params: { edit_token: token,
      student: { grade: "1", class_number: "1", attendance_number: "2", **attributes } }
  end

  it "shows target identifiers, three operations and empty secret inputs" do
    login
    student
    get admin_students_path
    row = document.at_css("[data-student-id='#{student.id}']")
    expect(row.css('td[data-label="操作"] a').map(&:text)).to eq([ "編集", "削除", "パスワード再設定" ])
    password_form
    expect(response.body).to include("MANAGE", "1年", "1組", "1番")
    expect(document.css('input[type="password"]').map { |field| field["value"] }).to all(be_blank)
    expect(response.headers["Cache-Control"]).to include("no-store")
    expect(response.body).not_to include(student.password_digest, "original-secret")
  end

  it "prevents Turbo snapshots on admin forms while retaining required confirmation and authentication" do
    login
    paths = [ admin_root_path, admin_students_path, edit_admin_student_path(student),
      confirm_destroy_admin_student_path(student), edit_admin_student_password_reset_path(student) ]
    paths.each do |path|
      get path
      expect(response).to have_http_status(:ok)
      expect(document.css('meta[name="turbo-cache-control"]').map { |meta| meta["content"] }).to eq([ "no-cache" ])
      expect(response.headers["Cache-Control"]).to include("no-store")
    end
    [ confirm_destroy_admin_student_path(student), edit_admin_student_password_reset_path(student) ].each do |path|
      get path
      form = document.at_css('input[name="edit_token"]').ancestors("form").first
      expect(form.at_css('input[name="confirmed"][type="checkbox"][required]')).to be_present
      expect(form.at_css('input[name="admin_password"][type="password"][required]')).to be_present
      expect(form.at_css('input[name="edit_token"]')["value"]).to be_present
    end
    preview_change
    expect(response).to have_http_status(:ok)
    expect(document.at_css('meta[name="turbo-cache-control"]')["content"]).to eq("no-cache")
    expect(document.at_css('input[name="confirmed"][required]')).to be_present
    expect(document.at_css('input[name="admin_password"][required]')).to be_present
    get student_login_path
    expect(document.css('meta[name="turbo-cache-control"]')).to be_empty
  end

  it "changes one of 30 students only, revokes the old session, and accepts the new login password only" do
    digest = student.password_digest
    Student.insert_all!((2..30).map { |number| { classroom_id: room.id, attendance_number: number, password_digest: digest } })
    other_students = Student.where.not(id: student.id).order(:id).map(&:attributes)
    client = ActionDispatch::Integration::Session.new(Rails.application)
    client.post student_login_path, params: { student_session: { school_code: school.school_code, grade: 1, class_number: 1,
      attendance_number: 1, password: "original-secret" } }
    expect(client.response.status).to eq(303)
    login
    reset_password
    expect(response).to redirect_to(admin_students_path)
    expect(student.reload.authenticate("739162840517294")).to eq(student)
    expect(Student.where.not(id: student.id).order(:id).map(&:attributes)).to eq(other_students)
    client.get student_assignments_path
    expect(client.response.status).to eq(303)
    expect(client.response.location).to end_with(student_login_path)
    post student_login_path, params: { student_session: { school_code: school.school_code, grade: 1, class_number: 1,
      attendance_number: 1, password: "original-secret" } }
    expect(response).to have_http_status(422)
    post student_login_path, params: { student_session: { school_code: school.school_code, grade: 1, class_number: 1,
      attendance_number: 1, password: "739162840517294" } }
    expect(response).to redirect_to(student_assignments_path)
  end

  it "expires reauthentication after 15 minutes without extending it on operations" do
    login
    travel_to Time.current.change(usec: 0) do
      reset_password
      expect(response).to have_http_status(:see_other)
      travel 14.minutes
      reset_password(password: "584217963045781", admin_password: "admin-secret")
      expect(response).to have_http_status(:see_other)
      travel 1.minute
      reset_password(password: "917304862551728", admin_password: nil)
      expect(response).to have_http_status(:unprocessable_content)
      expect(student.reload.authenticate("584217963045781")).to be_truthy
      reset_password(password: "917304862551728", admin_password: "admin-secret")
      expect(response).to have_http_status(:see_other)
    end
  end

  it "requires reauthentication again after logout, admin change, or admin password change" do
    login
    reset_password
    delete admin_logout_path
    login
    reset_password(admin_password: nil)
    expect(response).to have_http_status(:unprocessable_content)
    reset_password
    other = Admin.create!(school: school, user_id: "next-admin", password: "next-secret")
    login(other, "next-secret")
    reset_password(admin_password: nil)
    expect(response).to have_http_status(:unprocessable_content)
    login
    reset_password
    form_token = password_form
    original = student.reload.attributes
    admin.update!(password: "changed-admin-secret")
    reset_password(admin_password: nil, edit_token: form_token)
    expect(response).to redirect_to(admin_login_path)
    expect(student.reload.attributes).to eq(original)
    login(admin, "changed-admin-secret")
    reset_password(admin_password: nil)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "does not accept client-provided reauthentication flags or a wrong administrator password" do
    login
    original = student.password_digest
    reset_password(admin_password: nil, reauthenticated: "true", reauthenticated_at: Time.current.to_i)
    expect(response).to have_http_status(:unprocessable_content)
    reset_password(admin_password: "wrong")
    expect(response).to have_http_status(:unprocessable_content)
    reset_password(admin_password: "a\0b")
    expect(response).to have_http_status(:unprocessable_content)
    reset_password(password: "a\0b")
    expect(response).to have_http_status(:unprocessable_content)
    expect(student.reload.password_digest).to eq(original)
    reset_password
    reset_password(password: "381706249153820", admin_password: "wrong")
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "requires target confirmation and rejects tampered or stale tokens" do
    login
    original = student.password_digest
    reset_password(confirmed: "0")
    expect(response).to have_http_status(:unprocessable_content)
    reset_password(edit_token: "tampered")
    expect(response).to have_http_status(:unprocessable_content)
    expect(student.reload.password_digest).to eq(original)
    stale = password_form
    reset_password
    reset_password(password: "381706249153820", edit_token: stale)
    expect(response).to have_http_status(:unprocessable_content)
    expect(student.reload.authenticate("739162840517294")).to be_truthy
  end

  it "preserves list filters and page on return without an arbitrary redirect" do
    login
    form_token = password_form
    patch admin_student_password_reset_path(student, grade: 1, class_number: 1, page: 2), params: {
      edit_token: form_token, confirmed: "1", admin_password: "admin-secret", return_to: "https://example.invalid",
      student: { password: "739162840517294", password_confirmation: "739162840517294" } }
    expect(response).to redirect_to(admin_students_path(grade: 1, class_number: 1, page: 2))
  end

  it "rejects target identity, membership and hash injection" do
    login
    original = student.attributes
    [ { school_id: foreign_school.id }, { classroom_id: foreign_room.id }, { id: foreign_student.id },
      { attendance_number: 4 }, { grade: 2 }, { password_digest: "forged" } ].each do |injection|
      reset_password(student: { password: "739162840517294", password_confirmation: "739162840517294", **injection })
      expect(response).to have_http_status(:unprocessable_content)
      expect(student.reload.attributes).to eq(original)
    end
  end

  it "does not expose secrets in errors or Rails logs" do
    login
    form_token = password_form
    buffer = StringIO.new
    previous = Rails.logger
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(buffer))
    begin
      patch admin_student_password_reset_path(student), params: { edit_token: form_token, confirmed: "1", admin_password: "admin-secret",
        student: { password: "private-new-secret", password_confirmation: "private-mismatch" } }
    ensure
      Rails.logger = previous
    end
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body + buffer.string).not_to include("private-new-secret", "private-mismatch", "admin-secret", student.password_digest)
    expect(document.css('input[type="password"]').map { |field| field["value"] }).to all(be_blank)
  end

  it "requires a second step and fresh administrator password for editing even after reauthentication" do
    login
    reset_password
    preview_change(attendance_number: "3")
    expect(response.body).to include("生徒の変更内容を確認", "3番")
    confirmation_token = token
    expect(student.reload.attendance_number).to eq(1)
    patch admin_student_path(student), params: { edit_token: confirmation_token, confirmed: "1" }
    expect(response).to have_http_status(:unprocessable_content)
    preview_change(attendance_number: "3")
    patch admin_student_path(student), params: { edit_token: token, confirmed: "1", admin_password: "admin-secret" }
    expect(response).to redirect_to(admin_students_path)
    expect(student.reload.attendance_number).to eq(3)
  end

  it "allows safe pre-use membership corrections and rejects stale confirmations" do
    login
    preview_change(grade: "2", class_number: "3")
    expect(response).to have_http_status(:ok)
    stale = token
    student.update!(attendance_number: 4)
    patch admin_student_path(student), params: { edit_token: stale, confirmed: "1", admin_password: "admin-secret" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(student.reload.classroom).to eq(room)
    preview_change(grade: "2", class_number: "3")
    patch admin_student_path(student), params: { edit_token: token, confirmed: "1", admin_password: "admin-secret" }
    expect(response).to have_http_status(:see_other)
    expect(student.reload.classroom.grade).to eq(2)
  end

  it "rejects malformed edit selections and identity changes" do
    login
    get edit_admin_student_path(student)
    post confirm_update_admin_student_path(student), params: { edit_token: token,
      student: { grade: [ "1" ], class_number: "1", attendance_number: "2" } }
    expect(response).to have_http_status(:unprocessable_content)
    get edit_admin_student_path(student)
    post confirm_update_admin_student_path(student), params: { edit_token: token,
      student: { grade: "1", class_number: "1", attendance_number: "2", school_id: foreign_school.id } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(student.reload.attendance_number).to eq(1)
  end

  it "requires deletion confirmation and a fresh password, and deletes only the selected account" do
    login
    reset_password
    other = Student.create!(classroom: room, attendance_number: 2, password: "other-secret")
    get confirm_destroy_admin_student_path(student)
    expect(response.body).to include("MANAGE", "1年", "1組", "1番", "元に戻せません")
    delete admin_student_path(student), params: { edit_token: token, confirmed: "1" }
    expect(response).to have_http_status(:unprocessable_content)
    delete admin_student_path(student), params: { edit_token: token, admin_password: "admin-secret", confirmed: "0" }
    expect(response).to have_http_status(:unprocessable_content)
    delete admin_student_path(student), params: { edit_token: token, admin_password: "admin-secret", confirmed: "1" }
    expect(response).to redirect_to(admin_students_path)
    expect(Student.exists?(student.id)).to be(false)
    expect(other.reload).to be_persisted
    get confirm_destroy_admin_student_path(student.id)
    expect(response).to have_http_status(:not_found)
  end

  it "rejects cross-school viewing and every write endpoint without changing either account" do
    login
    original = foreign_student.attributes
    [ edit_admin_student_path(foreign_student), confirm_destroy_admin_student_path(foreign_student),
      edit_admin_student_password_reset_path(foreign_student) ].each do |path|
      get path
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include("FOREIGNMANAGE", foreign_student.password_digest)
    end
    post confirm_update_admin_student_path(foreign_student), params: { student: { grade: 1 } }
    expect(response).to have_http_status(:not_found)
    patch admin_student_path(foreign_student), params: { confirmed: "1", admin_password: "admin-secret" }
    expect(response).to have_http_status(:not_found)
    delete admin_student_path(foreign_student), params: { confirmed: "1", admin_password: "admin-secret" }
    expect(response).to have_http_status(:not_found)
    reset_password(target: foreign_student, edit_token: "tampered")
    expect(response).to have_http_status(:not_found)
    expect(foreign_student.reload.attributes).to eq(original)
  end

  it "rejects every operation for anonymous, teacher and student sessions" do
    teacher = Teacher.create!(school: school, user_id: "manage-teacher", password: "teacher-secret")
    3.times do |index|
      post login_path, params: { session: { user_id: teacher.user_id, password: "teacher-secret" } } if index == 1
      if index == 2
        post student_login_path, params: { student_session: { school_code: school.school_code, grade: 1, class_number: 1,
          attendance_number: student.attendance_number, password: "original-secret" } }
      end
      [ edit_admin_student_path(student), confirm_destroy_admin_student_path(student), edit_admin_student_password_reset_path(student) ].each do |path|
        get path
        expect(response).to redirect_to(admin_login_path)
      end
      post confirm_update_admin_student_path(student), params: { student: { grade: 1 } }
      expect(response).to redirect_to(admin_login_path)
      patch admin_student_path(student)
      expect(response).to redirect_to(admin_login_path)
      delete admin_student_path(student)
      expect(response).to redirect_to(admin_login_path)
      patch admin_student_password_reset_path(student)
      expect(response).to redirect_to(admin_login_path)
    end
    expect(student.reload.authenticate("original-secret")).to be_truthy
  end

  it "rejects password reset, edit preview, edit and deletion without CSRF tokens" do
    previous = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get admin_login_path
    csrf = document.at_css('input[name="authenticity_token"]')["value"]
    post admin_login_path, params: { authenticity_token: csrf, admin_session: { user_id: admin.user_id, password: "admin-secret" } }
    form_token = password_form
    patch admin_student_password_reset_path(student), params: { edit_token: form_token, confirmed: "1", admin_password: "admin-secret",
      student: { password: "739162840517294", password_confirmation: "739162840517294" } }
    expect(response).to have_http_status(:unprocessable_content)
    post confirm_update_admin_student_path(student), params: { edit_token: "x", student: { grade: 1 } }
    expect(response).to have_http_status(:unprocessable_content)
    patch admin_student_path(student), params: { confirmed: "1", admin_password: "admin-secret" }
    expect(response).to have_http_status(:unprocessable_content)
    delete admin_student_path(student), params: { confirmed: "1", admin_password: "admin-secret" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(student.reload.authenticate("original-secret")).to be_truthy
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end
end

RSpec.describe "Admin teacher password reauthentication", type: :request do
  include ActiveSupport::Testing::TimeHelpers
  let(:school) { School.create!(school_code: "TEACHERREAUTH") }
  let(:admin) { Admin.create!(school: school, user_id: "teacher-reauth-admin", password: "admin-secret") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher-reauth", password: "original-secret") }

  def edit_token
    get edit_admin_teacher_path(teacher)
    Nokogiri::HTML(response.body).at_css('input[name="teacher[edit_token]"]')["value"]
  end

  def change_password(admin_password: nil, confirmed: "1", token: edit_token)
    patch admin_teacher_path(teacher), params: { admin_password: admin_password, confirmed: confirmed,
      teacher: { password: "Long River 8 Beacon 42", password_confirmation: "Long River 8 Beacon 42", classroom_codes: [ "" ], edit_token: token } }
  end

  before do
    post admin_login_path, params: { admin_session: { user_id: admin.user_id, password: "admin-secret" } }
  end

  it "rejects missing confirmation or wrong reauthentication without changing credentials" do
    original = teacher.password_digest
    change_password
    expect(response).to have_http_status(:unprocessable_content)
    change_password(admin_password: "wrong")
    expect(response).to have_http_status(:unprocessable_content)
    change_password(admin_password: "admin-secret", confirmed: "0")
    expect(response).to have_http_status(:unprocessable_content)
    form_token = edit_token
    patch admin_teacher_path(teacher), params: { admin_password: "admin-secret", confirmed: "1",
      teacher: { password: "a\0b", password_confirmation: "a\0b", edit_token: form_token, classroom_codes: [ "" ] } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(teacher.reload.password_digest).to eq(original)
  end

  it "reuses the fixed window but checks the target token on every password change" do
    change_password(admin_password: "admin-secret")
    expect(response).to have_http_status(:see_other)
    stale = edit_token
    change_password
    expect(response).to have_http_status(:see_other)
    change_password(token: stale)
    expect(response).to have_http_status(:unprocessable_content)
    travel 15.minutes + 1.second do
      change_password
      expect(response).to have_http_status(:unprocessable_content)
    end
    expect(teacher.reload.authenticate("Long River 8 Beacon 42")).to be_truthy
  end

  it "expires old teacher edit confirmations even after fresh administrator reauthentication" do
    stale = edit_token
    travel 15.minutes + 1.second do
      change_password(admin_password: "admin-secret", token: stale)
      expect(response).to have_http_status(:unprocessable_content)
    end
    expect(teacher.reload.authenticate("original-secret")).to be_truthy
  end
end
