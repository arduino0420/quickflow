require "rails_helper"

RSpec.describe "Admin teacher management", type: :request do
  let(:school) { School.create!(school_code: "TEACHERADMIN") }
  let(:admin) { Admin.create!(school: school, user_id: "admin-teachers", password: "synthetic-admin-password") }
  let(:teacher) { Teacher.create!(school: school, user_id: "existing-teacher", password: "existing-teacher-password") }
  let(:classroom) { Classroom.create!(school: school, teachers: [ teacher ], grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "student-password") }
  let(:foreign_school) { School.create!(school_code: "FOREIGNTEACHERS") }
  let(:foreign_teacher) { Teacher.create!(school: foreign_school, user_id: "private-foreign-teacher", password: "foreign-password") }
  let(:foreign_classroom) { Classroom.create!(school: foreign_school, teachers: [ foreign_teacher ], grade: 3, class_number: 10) }
  let(:attributes) do
    { user_id: "registered-teacher", password: "Long River 8 Beacon 42", password_confirmation: "Long River 8 Beacon 42",
      classroom_codes: [ "1-1", "2-2" ] }
  end

  def login_admin
    post admin_login_path, params: { admin_session: { user_id: admin.user_id, password: "synthetic-admin-password" } }
    expect(response).to have_http_status(:see_other)
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def counts
    [ Teacher, Classroom, TeacherClassroom ].map(&:count)
  end

  it "lists only same-school teachers and classrooms and links the new form" do
    classroom
    foreign_classroom
    login_admin
    get admin_root_path
    expect(document.at_css("a[href='#{admin_teachers_path}']")).to be_present
    get admin_teachers_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(teacher.user_id, "1年1組")
    expect(response.body).not_to include(foreign_teacher.user_id, foreign_school.school_code)
    expect(document.at_css("a[href='#{new_admin_teacher_path}']").text).to eq("教師を新規登録")
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
  end

  it "aligns teacher ID, classrooms and edit links in separate columns with stacked navigation" do
    classroom
    login_admin
    get admin_teachers_path
    expect(document.css(".admin-teacher-list th").map(&:text)).to eq([ "教師ID", "担当クラス", "操作" ])
    row = document.at_css(".admin-teacher-list tbody tr")
    expect(row.css("td").size).to eq(3)
    expect(row.css("td").first(2).map { |cell| cell.text.strip }).to eq([ teacher.user_id, "1年1組" ])
    expect(row.css("td")[2].css("a").map(&:text)).to eq([ "編集", "パスワード再設定" ])
    expect(row.css("td")[2].css("a").map { |link| link[:href] }).to eq([
      edit_admin_teacher_path(teacher), edit_admin_teacher_path(teacher, anchor: "password-reset") ])
    expect(row.css("td")[0].at_css("a")).to be_nil
    expect(row.css("td")[2].at_css("a")[:href]).to eq(edit_admin_teacher_path(teacher))
    expect(document.css(".admin-teacher-list-actions a").map(&:text)).to eq([ "教師を新規登録", "管理者トップに戻る" ])
  end

  it "does not disclose historical cross-school relationships in the list" do
    TeacherClassroom.new(teacher: teacher, classroom: foreign_classroom).save!(validate: false)
    login_admin
    get admin_teachers_path

    expect(response.body).to include(teacher.user_id, "担当なし")
    expect(response.body).not_to include("3年10組", foreign_teacher.user_id, foreign_school.school_code)
  end

  it "renders the exact field order, read-only school code and all 30 unique checkboxes" do
    login_admin
    get new_admin_teacher_path

    expect(response).to have_http_status(:ok)
    form = document.at_css("form[action='#{admin_teachers_path}']")
    names = form.css("input").map { |field| field[:name] }
    expect(names.index("school_code")).to be < names.index("teacher[user_id]")
    expect(names.index("teacher[user_id]")).to be < names.index("teacher[password]")
    expect(names.index("teacher[password]")).to be < names.index("teacher[classroom_codes][]")
    expect(form.at_css("input[name='school_code']")[:readonly]).to be_present
    expect(form.at_css("input[name='school_code']")[:value]).to eq(school.school_code)
    expect(form.css("input[type='password']").map { |field| field[:value] }).to all(be_blank)
    boxes = form.css("input[type='checkbox']")
    expect(boxes.map { |field| field[:value] }).to eq(Admin::TeacherRegistration::CLASSROOM_CODES)
    expect(boxes.map { |field| field[:id] }.uniq.size).to eq(30)
    expect(form.at_css("input[type='submit']")[:value]).to eq("教師を登録する")
  end

  it "registers a teacher, reuses a shared class and creates only another selected class" do
    classroom
    original = classroom.teacher_classrooms.sole.attributes
    login_admin
    post admin_teachers_path, params: { school_code: "forged", teacher: attributes.merge(school_code: "forged") }

    expect(response).to redirect_to(admin_teachers_path)
    expect(response).to have_http_status(:see_other)
    created = Teacher.find_by!(user_id: attributes[:user_id])
    expect(created.school).to eq(school)
    expect(created.authenticate(attributes[:password])).to eq(created)
    expect(created.password_digest).not_to eq(attributes[:password])
    expect(created.classrooms.pluck(:grade, :class_number)).to match_array([ [ 1, 1 ], [ 2, 2 ] ])
    expect(school.classrooms.count).to eq(2)
    expect(classroom.reload.teachers).to contain_exactly(teacher, created)
    expect(TeacherClassroom.find(original['id']).attributes).to eq(original)
    follow_redirect!
    expect(response.body).to include("教師アカウントを登録しました。", created.user_id)
  end

  it "permits registration with zero classrooms" do
    login_admin
    post admin_teachers_path, params: { teacher: attributes.except(:classroom_codes) }

    expect(response).to redirect_to(admin_teachers_path)
    expect(Teacher.find_by!(user_id: attributes[:user_id]).classrooms).to be_empty
    expect(Classroom.count).to eq(0)
  end

  [ { password_confirmation: "different" }, { password_confirmation: "" }, { password: "", password_confirmation: "" },
    { user_id: "" }, { classroom_codes: [ "4-1" ] }, { classroom_codes: [ "1-11" ] }, { classroom_codes: "1-1" } ].each do |change|
    it "rejects invalid input without partial records: #{change.keys.inspect} #{change.values.map(&:class)}" do
      login_admin
      original = counts
      post admin_teachers_path, params: { teacher: attributes.merge(change) }

      expect(response).to have_http_status(422)
      expect(counts).to eq(original)
      expect(document.at_css("[role='alert']")).to be_present
      expect(document.css("input[type='password']").map { |field| field[:value] }).to all(be_blank)
      expect(response.body).not_to include("synthetic-teacher-password", "different")
    end
  end

  it "rejects duplicate IDs without modifying the existing teacher" do
    teacher
    original = teacher.attributes
    login_admin
    before_counts = counts
    post admin_teachers_path, params: { teacher: attributes.merge(user_id: teacher.user_id) }

    expect(response).to have_http_status(422)
    expect(counts).to eq(before_counts)
    expect(teacher.reload.attributes).to eq(original)
  end

  [ :school_id, :classroom_id, :classroom_ids ].each do |key|
    [ :root, :teacher ].each do |location|
      it "rejects foreign #{key} at #{location} without writes" do
        foreign_classroom
        login_admin
        before_counts = counts
        value = key == :school_id ? foreign_school.id : foreign_classroom.id
        value = [ value.to_s ] if key == :classroom_ids
        payload = { teacher: attributes }
        location == :root ? payload[key] = value : payload[:teacher][key] = value
        post admin_teachers_path, params: payload

        expect(response).to have_http_status(422)
        expect(counts).to eq(before_counts)
        expect(response.body).not_to include(foreign_school.school_code, foreign_teacher.user_id)
      end
    end
  end

  it "ignores forged IDs, roles and password digests without updating another account" do
    teacher
    original = teacher.attributes
    login_admin
    post admin_teachers_path, params: { teacher: attributes.merge(id: teacher.id, role: "admin", admin_id: admin.id,
      password_digest: "forged") }

    expect(response).to redirect_to(admin_teachers_path)
    expect(teacher.reload.attributes).to eq(original)
    expect(Admin.count).to eq(1)
    expect(Teacher.find_by!(user_id: attributes[:user_id]).authenticate(attributes[:password])).to be_truthy
  end

  it "rolls back and displays a safe error if saving a second relationship fails" do
    login_admin
    original = counts
    allow_any_instance_of(TeacherClassroom).to receive(:save!).and_wrap_original do |method, *args, **kwargs|
      raise ActiveRecord::RecordNotUnique, "private database details" if method.receiver.classroom.grade == 2
      method.call(*args, **kwargs)
    end
    post admin_teachers_path, params: { teacher: attributes }

    expect(response).to have_http_status(422)
    expect(counts).to eq(original)
    expect(response.body).not_to include("private database details", attributes[:password])
  end

  [ :anonymous, :teacher, :student ].each do |actor|
    it "rejects #{actor} from listing, new form and creation" do
      if actor == :teacher
        post login_path, params: { session: { user_id: teacher.user_id, password: "existing-teacher-password" } }
      elsif actor == :student
        post student_login_path, params: { student_session: { school_code: school.school_code, grade: 1, class_number: 1,
          attendance_number: student.attendance_number, password: "student-password" } }
      end
      original = counts
      [ admin_teachers_path, new_admin_teacher_path ].each do |path|
        get path
        expect(response).to redirect_to(admin_login_path)
      end
      post admin_teachers_path, params: { teacher: attributes }
      expect(response).to redirect_to(admin_login_path)
      expect(counts).to eq(original)
    end
  end

  it "requires a valid CSRF token for creation" do
    original_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get admin_login_path
    token = document.at_css("input[name='authenticity_token']")[:value]
    post admin_login_path, params: { authenticity_token: token, admin_session: { user_id: admin.user_id, password: "synthetic-admin-password" } }
    get new_admin_teacher_path
    token = document.at_css("form[action='#{admin_teachers_path}'] input[name='authenticity_token']")[:value]
    original = counts

    post admin_teachers_path, params: { teacher: attributes }
    expect(response).to have_http_status(422)
    expect(counts).to eq(original)
    post admin_teachers_path, params: { authenticity_token: token, teacher: attributes }
    expect(response).to redirect_to(admin_teachers_path)
  ensure
    ActionController::Base.allow_forgery_protection = original_protection
  end

  it "does not leak passwords or hashes on validation failure" do
    login_admin
    buffer = StringIO.new
    owners = [ Rails, ActionController::Base, ActiveRecord::Base ]
    originals = owners.to_h { |owner| [ owner, owner.logger ] }
    begin
      owners.each { |owner| owner.logger = ActiveSupport::Logger.new(buffer) }
      post admin_teachers_path, params: { teacher: attributes.merge(password_confirmation: "private-confirmation") }
    ensure
      originals.each { |owner, logger| owner.logger = logger }
    end

    expect(response).to have_http_status(422)
    expect(response.body).not_to include(attributes[:password], "private-confirmation")
    expect(buffer.string).not_to include(attributes[:password], "private-confirmation")
  end

  it "does not expose teacher deletion" do
    login_admin
    teacher
    expect { delete "/admin/teachers/#{teacher.id}" }.not_to change(Teacher, :count)
    expect(response).to have_http_status(:not_found)
  end
end
