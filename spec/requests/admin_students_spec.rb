require "rails_helper"

RSpec.describe "Admin student registration", type: :request do
  let(:school) { School.create!(school_code: "ADMINSTUDENT") }
  let(:admin) { Admin.create!(school: school, user_id: "student-admin", password: "synthetic-admin-password") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher", password: "teacher-password") }
  let(:classroom) { Classroom.create!(school: school, grade: 1, class_number: 1, teachers: [ teacher ]) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "existing-password") }
  let(:attributes) { { grade: "1", class_number: "1", attendance_number: "2", password: "58392047", password_confirmation: "58392047" } }

  def login_admin
    post admin_login_path, params: { admin_session: { user_id: admin.user_id, password: "synthetic-admin-password" } }
    expect(response).to have_http_status(:see_other)
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def counts
    [ Student, Classroom, TeacherClassroom ].map(&:count)
  end

  it "shows the ordered fixed-school form, options and top-page link with unified branding" do
    get admin_login_path
    expect(document.at_css(".app-brand").text).to eq("QuickFlow")
    login_admin
    get admin_root_path
    expect(document.at_css(".app-brand").text).to eq("QuickFlow")
    expect(document.at_css("a[href='#{new_admin_student_path}']").text).to eq("生徒を新規登録")
    get new_admin_student_path
    expect(response).to have_http_status(:ok)
    form = document.at_css("form[action='#{admin_students_path}']")
    names = form.css("input, select").map { |field| field[:name] }
    fields = [ "school_code", "student[grade]", "student[class_number]", "student[attendance_number]", "student[password]", "student[password_confirmation]" ]
    expect(fields.map { |field| names.index(field) }).to eq(fields.map { |field| names.index(field) }.sort)
    expect(form.at_css("input[name='school_code']")[:readonly]).to be_present
    expect(form.at_css("input[name='school_code']")[:value]).to eq(school.school_code)
    { grade: [ 3, "年" ], class_number: [ 10, "組" ], attendance_number: [ 40, "番" ] }.each do |field, (maximum, suffix)|
      select = form.at_css("select[name='student[#{field}]']")
      expect(select.css("option").map { |option| [ option[:value], option.text ] }).to eq(
        [ [ "", "選択してください" ] ] + (1..maximum).map { |n| [ n.to_s, "#{n}#{suffix}" ] }
      )
    end
    expect(form.at_css("input[type='submit']")[:value]).to eq("生徒を登録する")
    expect(form.css("input[type='password']").map { |input| input[:value] }).to all(be_blank)
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
  end

  it "creates only the selected new classroom and allows existing student login" do
    login_admin
    expect { post admin_students_path, params: { school_code: school.school_code, student: attributes } }.to change(Student, :count).by(1).and change(Classroom, :count).by(1)
    expect(response).to redirect_to(new_admin_student_path)
    pupil = Student.last
    expect(pupil.classroom.school).to eq(school)
    expect(pupil.authenticate(attributes[:password])).to eq(pupil)
    expect(pupil.password_digest).not_to eq(attributes[:password])
    expect(TeacherClassroom.count).to eq(0)
    follow_redirect!
    expect(response.body).to include("生徒アカウントを登録しました。")
    post student_login_path, params: { student_session: attributes.slice(:grade, :class_number, :attendance_number, :password).merge(school_code: school.school_code) }
    expect(response).to redirect_to(student_assignments_path)
    expect(request.session[:student_id]).to eq(pupil.id)
    expect(request.session[:admin_id]).to be_nil
  end

  it "reuses an existing classroom and preserves other students and teacher relationships" do
    student
    original = [ classroom, teacher, student, classroom.teacher_classrooms.sole ].map(&:attributes)
    login_admin
    expect { post admin_students_path, params: { student: attributes } }.to change(Student, :count).by(1).and change(Classroom, :count).by(0)
    expect(response).to redirect_to(new_admin_student_path)
    expect([ classroom, teacher, student, classroom.teacher_classrooms.sole ].map { |record| record.reload.attributes }).to eq(original)
  end

  it "rejects duplicate students without changing the existing password or data" do
    student
    original = student.attributes
    login_admin
    before_counts = counts
    post admin_students_path, params: { student: attributes.merge(attendance_number: "1") }
    expect(response).to have_http_status(422)
    expect(counts).to eq(before_counts)
    expect(student.reload.attributes).to eq(original)
  end

  [ { password_confirmation: "different" }, { password_confirmation: "" }, { password_confirmation: nil },
    { password: "", password_confirmation: "" }, { grade: "4" }, { grade: "" }, { class_number: "11" },
    { attendance_number: "41" }, { grade: [ "1" ] }, { class_number: "1.5" } ].each do |change|
    it "rejects invalid input without partial creation: #{change.keys} #{change.values.map(&:class)}" do
      login_admin
      original = counts
      post admin_students_path, params: { student: attributes.merge(change) }
      expect(response).to have_http_status(422)
      expect(counts).to eq(original)
      expect(document.at_css("[role='alert']")).to be_present
      expect(document.css("input[type='password']").map { |input| input[:value] }).to all(be_blank)
      expect(response.body).not_to include(attributes[:password], "different")
    end
  end

  [ :school_id, :classroom_id, :classroom_ids, :school_code ].each do |field|
    [ :root, :nested ].each do |location|
      it "rejects foreign #{field} at #{location} without writes" do
        foreign_school = School.create!(school_code: "FOREIGNSTUDENT")
        foreign_class = Classroom.create!(school: foreign_school, grade: 1, class_number: 1)
        login_admin
        original = counts
        value = { school_id: foreign_school.id, classroom_id: foreign_class.id,
          classroom_ids: [ foreign_class.id ], school_code: foreign_school.school_code }.fetch(field)
        payload = { student: attributes }
        if location == :root
          payload[field] = value
        else
          payload[:student][field] = value
        end
        post admin_students_path, params: payload
        expect(response).to have_http_status(422)
        expect(counts).to eq(original)
        expect(foreign_class.reload.students).to be_empty
        expect(response.body).not_to include(foreign_school.school_code)
      end
    end
  end

  [ :anonymous, :teacher, :student ].each do |actor|
    it "rejects #{actor} from the admin form and registration" do
      if actor == :teacher
        post login_path, params: { session: { user_id: teacher.user_id, password: "teacher-password" } }
      elsif actor == :student
        post student_login_path, params: { student_session: { school_code: school.school_code, grade: 1,
          class_number: 1, attendance_number: student.attendance_number, password: "existing-password" } }
      end
      original = counts
      get new_admin_student_path
      expect(response).to redirect_to(admin_login_path)
      post admin_students_path, params: { student: attributes }
      expect(response).to redirect_to(admin_login_path)
      expect(counts).to eq(original)
    end
  end

  it "rolls back a new classroom and displays no raw DB details on uniqueness races" do
    login_admin
    original = counts
    allow_any_instance_of(Student).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique, "private SQL details")
    post admin_students_path, params: { student: attributes }
    expect(response).to have_http_status(422)
    expect(counts).to eq(original)
    expect(response.body).not_to include("private SQL details", attributes[:password])
  end

  it "filters passwords from logs and error responses" do
    login_admin
    output = StringIO.new
    owners = [ Rails, ActionController::Base, ActiveRecord::Base ]
    originals = owners.to_h { |owner| [ owner, owner.logger ] }
    begin
      owners.each { |owner| owner.logger = ActiveSupport::Logger.new(output) }
      post admin_students_path, params: { student: attributes.merge(password_confirmation: "private-confirmation") }
    ensure
      originals.each { |owner, logger| owner.logger = logger }
    end
    expect(response).to have_http_status(422)
    expect(output.string + response.body).not_to include(attributes[:password], "private-confirmation")
  end

  it "maintains CSRF protection" do
    protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get admin_login_path
    token = document.at_css("input[name='authenticity_token']")[:value]
    post admin_login_path, params: { authenticity_token: token, admin_session: { user_id: admin.user_id, password: "synthetic-admin-password" } }
    get new_admin_student_path
    token = document.at_css("form[action='#{admin_students_path}'] input[name='authenticity_token']")[:value]
    original = counts
    post admin_students_path, params: { student: attributes }
    expect(response).to have_http_status(422)
    expect(counts).to eq(original)
    post admin_students_path, params: { authenticity_token: token, student: attributes }
    expect(response).to redirect_to(new_admin_student_path)
  ensure
    ActionController::Base.allow_forgery_protection = protection
  end
end

RSpec.describe "Admin student listing", type: :request do
  let!(:school) { School.create!(school_code: "LISTING") }
  let!(:admin) { Admin.create!(school: school, user_id: "listing-admin", password: "admin-password") }
  let!(:classroom) { Classroom.create!(school: school, grade: 1, class_number: 1) }

  def add_students(room, numbers)
    digest = BCrypt::Password.create("student-password")
    Student.insert_all!(numbers.map { |number| { classroom_id: room.id, attendance_number: number, password_digest: digest } })
    Student.where(classroom: room).order(:attendance_number).pluck(:id)
  end

  def login
    post admin_login_path, params: { admin_session: { user_id: admin.user_id, password: "admin-password" } }
  end

  def listed_ids
    Nokogiri::HTML(response.body).css("[data-student-id]").map { |row| row["data-student-id"].to_i }
  end

  it "scopes rows, counts and filter options to the administrator's school" do
    own_ids = add_students(classroom, [ 1 ])
    foreign_school = School.create!(school_code: "FOREIGNLIST")
    foreign_room = Classroom.create!(school: foreign_school, grade: 6, class_number: 15)
    foreign_ids = add_students(foreign_room, [ 1 ])
    login
    get admin_students_path, params: { school_id: foreign_school.id, classroom_id: foreign_room.id }
    expect(response).to have_http_status(:ok)
    expect(listed_ids).to eq(own_ids)
    expect(listed_ids & foreign_ids).to be_empty
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('[role="status"]').text).to include("全1件")
    expect(document.css('#grade option').map { |option| option["value"] }).to eq([ "", "1" ])
    expect(document.css('#class_number option').map { |option| option["value"] }).to eq([ "", "1" ])
    get admin_students_path, params: { grade: 6, class_number: 15 }
    expect(listed_ids).to be_empty
    expect(response.body).to include("全0件")
    other_admin = Admin.create!(school: foreign_school, user_id: "foreign-list-admin", password: "admin-password")
    post admin_login_path, params: { admin_session: { user_id: other_admin.user_id, password: "admin-password" } }
    get admin_students_path, params: { school_id: school.id }
    expect(listed_ids).to eq(foreign_ids)
  end

  it "sorts by grade, class, attendance number and id, with 40 rows per page" do
    later_room = Classroom.create!(school: school, grade: 2, class_number: 1)
    middle_room = Classroom.create!(school: school, grade: 1, class_number: 2)
    later = add_students(later_room, [ 2, 1 ])
    middle = add_students(middle_room, [ 1 ])
    first = add_students(classroom, (1..40).to_a.reverse)
    login
    get admin_students_path
    expect(listed_ids).to eq(first)
    get admin_students_path, params: { page: 2 }
    expect(listed_ids).to eq(middle + later)
    get admin_students_path, params: { page: 999999999 }
    expect(listed_ids).to eq(middle + later)
  end

  it "filters independently and together, preserves filters in page links, and resets the page in the form" do
    other = Classroom.create!(school: school, grade: 1, class_number: 2)
    second_grade = Classroom.create!(school: school, grade: 2, class_number: 1)
    first = add_students(classroom, (1..40).to_a)
    extra = add_students(other, [ 1 ])
    second = add_students(second_grade, [ 1 ])
    login
    get admin_students_path, params: { grade: 1 }
    expect(listed_ids).to eq(first)
    document = Nokogiri::HTML(response.body)
    expect(document.at_css('a[rel="next"]')["href"]).to include("grade=1", "page=2")
    expect(document.css('form input[name="page"]')).to be_empty
    get admin_students_path, params: { grade: 1, page: 2 }
    expect(listed_ids).to eq(extra)
    get admin_students_path, params: { class_number: 1 }
    expect(listed_ids).to eq(first)
    get admin_students_path, params: { grade: 2, class_number: 1 }
    expect(listed_ids).to eq(second)
  end

  it "supports historical classroom ranges and empty lists" do
    login
    get admin_students_path
    expect(response.body).to include("該当する生徒はいません。", "1 / 1ページ")
    historical = Classroom.create!(school: school, grade: 6, class_number: 15)
    ids = add_students(historical, [ 40 ])
    get admin_students_path, params: { grade: 6, class_number: 15 }
    expect(listed_ids).to eq(ids)
    expect(response.body).to include("利用可能")
  end

  it "rejects malformed filters and page numbers without server errors" do
    login
    [ { grade: "0" }, { grade: "7" }, { grade: [ "1" ] }, { grade: { value: "1" } },
      { class_number: "16" }, { class_number: "1 OR 1=1" }, { class_number: [ "1" ] },
      { page: "0" }, { page: "-1" }, { page: "1.5" }, { page: "9" * 100 },
      { page: [ "1" ] }, { page: { value: "1" } } ].each do |parameters|
      get admin_students_path, params: parameters
      expect(response).to have_http_status(:bad_request), parameters.inspect
      expect(listed_ids).to be_empty
    end
    get admin_students_path, params: { grade: "", class_number: "", page: "" }
    expect(response).to have_http_status(:ok)
  end

  it "redirects anonymous, teacher and student sessions to admin login" do
    get admin_students_path
    expect(response).to redirect_to(admin_login_path)
    teacher = Teacher.create!(school: school, user_id: "listing-teacher", password: "teacher-password")
    post login_path, params: { session: { user_id: teacher.user_id, password: "teacher-password" } }
    expect(response).to redirect_to(assignments_path)
    get admin_students_path
    expect(response).to redirect_to(admin_login_path)
    add_students(classroom, [ 1 ])
    post student_login_path, params: { student_session: { school_code: school.school_code, grade: 1, class_number: 1, attendance_number: 1, password: "student-password" } }
    expect(response).to redirect_to(student_assignments_path)
    get admin_students_path
    expect(response).to redirect_to(admin_login_path)
  end

  it "preloads classrooms with a bounded number of queries" do
    5.times do |index|
      room = Classroom.create!(school: school, grade: 2, class_number: index + 1)
      add_students(room, [ 1, 2 ])
    end
    login
    queries = []
    subscriber = ->(event) { queries << event.payload[:sql] if event.payload[:sql].match?(/SELECT.*FROM "classrooms"/i) }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { get admin_students_path }
    expect(listed_ids.size).to eq(10)
    expect(queries.size).to be <= 2
    expect(response.body).not_to include("password_digest", "student-password")
  end
end
