require "rails_helper"

RSpec.describe "Admin teacher editing", type: :request do
  let(:school) { School.create!(school_code: "EDITADMIN") }
  let(:admin) { Admin.create!(school: school, user_id: "edit-admin", password: "admin-password") }
  let(:teacher) { Teacher.create!(school: school, user_id: "edit-teacher", password: "teacher-password") }
  let(:classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "student-password") }
  let(:foreign_school) { School.create!(school_code: "FOREIGNEDIT") }
  let(:foreign_teacher) { Teacher.create!(school: foreign_school, user_id: "private-foreign-teacher", password: "foreign-password") }
  let(:attributes) { { password: "", password_confirmation: "", classroom_codes: [ "1-1", "2-2" ], edit_token: @token } }

  def document
    Nokogiri::HTML(response.body)
  end

  def edit_form
    post admin_login_path, params: { admin_session: { user_id: admin.user_id, password: "admin-password" } }
    get edit_admin_teacher_path(teacher)
    expect(response).to have_http_status(:ok)
    @token = document.at_css("input[name='teacher[edit_token]']")[:value]
  end

  def counts
    [ Teacher, Classroom, TeacherClassroom ].map(&:count)
  end

  it "displays immutable fields, password fields and 30 checkboxes with current assignments selected" do
    classroom
    edit_form
    names = document.css("form input").map { |field| field[:name] }
    ordered = [ "school_code", "teacher[user_id]", "teacher[password]", "teacher[password_confirmation]", "teacher[classroom_codes][]" ]
    expect(ordered.map { |name| names.index(name) }).to eq(ordered.map { |name| names.index(name) }.sort)
    expect(document.at_css("input[name='school_code']")[:readonly]).to be_present
    expect(document.at_css("input[name='teacher[user_id]']")[:readonly]).to be_present
    expect(document.at_css("input[name='teacher[user_id]']")[:value]).to eq(teacher.user_id)
    expect(document.css("input[type='password']").map { |field| field[:value] }).to all(be_blank)
    expect(document.css("input[name='teacher[classroom_codes][]'][type='checkbox']").size).to eq(30)
    expect(document.css("input[type='checkbox'][checked]").map { |field| field[:value] }).to eq([ "1-1" ])
    expect(document.css("input[name='confirmed'][type='checkbox']").size).to eq(1)
    expect(document.at_css("input[type='submit']")[:value]).to eq("変更を保存する")
    expect(response.body).not_to include(teacher.password_digest, "teacher-password")
    get admin_teachers_path
    expect(document.at_css("a[href='#{edit_admin_teacher_path(teacher)}']")).to be_present
  end

  it "updates assignments and preserves the password when submitted blank" do
    classroom
    original_digest = teacher.password_digest
    edit_form
    patch admin_teacher_path(teacher), params: { school_code: school.school_code,
      teacher: attributes.merge(user_id: teacher.user_id, classroom_codes: [ "2-2", "3-10" ]) }
    expect(response).to redirect_to(admin_teachers_path)
    expect(teacher.reload.password_digest).to eq(original_digest)
    expect(teacher.classrooms.pluck(:grade, :class_number)).to match_array([ [ 2, 2 ], [ 3, 10 ] ])
    expect(classroom.reload.teachers).to be_empty
  end

  it "allows zero assignments" do
    classroom
    edit_form
    patch admin_teacher_path(teacher), params: { teacher: attributes.merge(classroom_codes: [ "" ]) }
    expect(response).to redirect_to(admin_teachers_path)
    expect(teacher.reload.classrooms).to be_empty
    expect(classroom.reload).to be_persisted
  end

  it "resets a password and allows teacher login with the new password only" do
    edit_form
    patch admin_teacher_path(teacher), params: { admin_password: "admin-password", confirmed: "1", teacher: attributes.merge(password: "Matsue2026", password_confirmation: "Matsue2026") }
    expect(response).to redirect_to(admin_teachers_path)
    post login_path, params: { session: { user_id: teacher.user_id, password: "teacher-password" } }
    expect(response).to have_http_status(422)
    post login_path, params: { session: { user_id: teacher.user_id, password: "Matsue2026" } }
    expect(response).to redirect_to(assignments_path)
  end

  it "rejects an old teacher session after password reset and accepts the new credential" do
    teacher_client = ActionDispatch::Integration::Session.new(Rails.application)
    teacher_client.post login_path, params: { session: { user_id: teacher.user_id, password: "teacher-password" } }
    expect(teacher_client.response.status).to eq(303)
    expect(teacher_client.response.location).to end_with(assignments_path)
    edit_form
    patch admin_teacher_path(teacher), params: { admin_password: "admin-password", confirmed: "1", teacher: attributes.merge(password: "Matsue2026", password_confirmation: "Matsue2026") }
    expect(response).to redirect_to(admin_teachers_path)
    teacher_client.get assignments_path
    expect(teacher_client.response.status).to eq(303)
    expect(teacher_client.response.location).to end_with(login_path)
    teacher_client.post login_path, params: { session: { user_id: teacher.user_id, password: "Matsue2026" } }
    teacher_client.get assignments_path
    expect(teacher_client.response.status).to eq(200)
  end

  [ { password: "private-edited-secret", password_confirmation: "wrong" }, { password: "private-edited-secret", password_confirmation: "" },
    { classroom_codes: [ "4-1" ] }, { classroom_codes: [ "1-11" ] }, { classroom_codes: "1-1" },
    { edit_token: "tampered" }, { edit_token: nil } ].each do |change|
    it "rejects invalid input #{change.keys} without writes or password disclosure" do
      classroom
      edit_form
      original = [ teacher.reload.attributes, counts, teacher.teacher_classrooms.sole.attributes ]
      patch admin_teacher_path(teacher), params: { admin_password: "admin-password", confirmed: "1", teacher: attributes.merge(change) }
      expect(response).to have_http_status(422)
      expect([ teacher.reload.attributes, counts, teacher.teacher_classrooms.sole.attributes ]).to eq(original)
      expect(document.css("input[type='password']").map { |field| field[:value] }).to all(be_blank)
      expect(response.body).not_to include("private-edited-secret", "wrong")
    end
  end

  [ :school_id, :teacher_id, :classroom_id, :classroom_ids, :user_id, :school_code ].each do |key|
    [ :root, :nested ].each do |location|
      it "rejects altered #{key} at #{location}" do
        foreign_teacher
        classroom
        edit_form
        original = teacher.attributes
        original_counts = counts
        payload = { teacher: attributes }
        value = { school_id: foreign_school.id, teacher_id: foreign_teacher.id, classroom_id: 999999,
          classroom_ids: [ "999999" ], user_id: foreign_teacher.user_id, school_code: foreign_school.school_code }.fetch(key)
        if location == :root
          payload[key] = value
        else
          payload[:teacher][key] = value
        end
        patch admin_teacher_path(teacher), params: payload
        expect(response).to have_http_status(422)
        expect(teacher.reload.attributes).to eq(original)
        expect(counts).to eq(original_counts)
        expect(response.body).not_to include(foreign_teacher.user_id, foreign_school.school_code)
      end
    end
  end

  it "rejects another school's teacher before reading or updating it" do
    edit_form
    original = foreign_teacher.attributes
    get edit_admin_teacher_path(foreign_teacher)
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include(foreign_teacher.user_id, foreign_school.school_code)
    patch admin_teacher_path(foreign_teacher), params: { teacher: attributes }
    expect(response).to have_http_status(:not_found)
    expect(foreign_teacher.reload.attributes).to eq(original)
  end

  it "rejects a stale form after another admin request has saved" do
    edit_form
    stale = @token
    patch admin_teacher_path(teacher), params: { teacher: attributes.merge(classroom_codes: [ "2-2" ]) }
    expect(response).to redirect_to(admin_teachers_path)
    saved = teacher.reload.attributes
    patch admin_teacher_path(teacher), params: { teacher: attributes.merge(edit_token: stale, classroom_codes: [ "3-10" ]) }
    expect(response).to have_http_status(422)
    expect(response.body).to include("開き直してください")
    expect(teacher.reload.attributes).to eq(saved)
    expect(teacher.classrooms.pluck(:grade, :class_number)).to eq([ [ 2, 2 ] ])
    expect(Classroom.exists?(school: school, grade: 3, class_number: 10)).to be(false)
  end

  [ :anonymous, :teacher, :student ].each do |actor|
    it "rejects #{actor} from edit and update without changes" do
      teacher
      if actor == :teacher
        post login_path, params: { session: { user_id: teacher.user_id, password: "teacher-password" } }
      elsif actor == :student
        post student_login_path, params: { student_session: { school_code: school.school_code, grade: 1, class_number: 1,
          attendance_number: student.attendance_number, password: "student-password" } }
      end
      original = [ teacher.reload.attributes, counts ]
      get edit_admin_teacher_path(teacher)
      expect(response).to redirect_to(admin_login_path)
      patch admin_teacher_path(teacher), params: { teacher: attributes }
      expect(response).to redirect_to(admin_login_path)
      expect([ teacher.reload.attributes, counts ]).to eq(original)
    end
  end

  it "requires a valid CSRF token for an update" do
    protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get admin_login_path
    csrf = document.at_css("input[name='authenticity_token']")[:value]
    post admin_login_path, params: { authenticity_token: csrf, admin_session: { user_id: admin.user_id, password: "admin-password" } }
    get edit_admin_teacher_path(teacher)
    @token = document.at_css("input[name='teacher[edit_token]']")[:value]
    csrf = document.at_css("form[action='#{admin_teacher_path(teacher)}'] input[name='authenticity_token']")[:value]
    original = [ teacher.attributes, counts ]
    patch admin_teacher_path(teacher), params: { teacher: attributes }
    expect(response).to have_http_status(422)
    expect([ teacher.reload.attributes, counts ]).to eq(original)
    patch admin_teacher_path(teacher), params: { authenticity_token: csrf, teacher: attributes }
    expect(response).to redirect_to(admin_teachers_path)
  ensure
    ActionController::Base.allow_forgery_protection = protection
  end

  it "does not log passwords on validation failure" do
    edit_form
    output = StringIO.new
    owners = [ Rails, ActionController::Base, ActiveRecord::Base ]
    originals = owners.to_h { |owner| [ owner, owner.logger ] }
    begin
      owners.each { |owner| owner.logger = ActiveSupport::Logger.new(output) }
      patch admin_teacher_path(teacher), params: { admin_password: "admin-password", confirmed: "1", teacher: attributes.merge(password: "private-Matsue2026", password_confirmation: "private-confirmation") }
    ensure
      originals.each { |owner, logger| owner.logger = logger }
    end
    expect(response).to have_http_status(422)
    expect(response.body + output.string).not_to include("private-Matsue2026", "private-confirmation")
  end
end
