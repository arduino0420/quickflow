require "rails_helper"

RSpec.describe "Teacher-managed student registration", type: :request do
  let(:school) { School.create!(school_code: "REGISTER") }
  let(:teacher) { Teacher.create!(school: school, user_id: "register-teacher", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:attributes) { { classroom_id: classroom.id.to_s, attendance_number: "1", password: "password123", password_confirmation: "password123" } }

  def login
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
  end

  def document
    Nokogiri::HTML(response.body)
  end

  it "registers a student in the teacher's class using a hashed password and keeps the teacher session" do
    classroom
    login
    get assignments_path
    expect(document.at_css("a[href='#{new_student_path}']")).to be_nil
    get new_student_path
    expect(document.at_css("input[name='student[password]']")[:type]).to eq("password")
    expect(document.at_css("input[name='student[password]']")[:autocomplete]).to eq("new-password")
    expect { post students_path, params: { student: attributes } }.to change(Student, :count).by(1)
    expect(response).to redirect_to(new_student_path)
    pupil = Student.last
    expect(pupil.classroom).to eq(classroom)
    expect(pupil.password_digest).not_to eq("password123")
    expect(pupil.authenticate("password123")).to eq(pupil)
    get assignments_path
    expect(response).to have_http_status(:ok)
    get student_assignments_path
    expect(response).to redirect_to(student_login_path)
    post student_login_path, params: { student_session: {
      school_code: school.school_code, grade: 1, class_number: 1, attendance_number: 1, password: "password123"
    } }
    expect(response).to redirect_to(student_assignments_path)
    get assignments_path
    expect(response).to redirect_to(login_path)
  end

  [ { attendance_number: "0" }, { attendance_number: "1.5" }, { attendance_number: "1abc" }, { attendance_number: "" }, { attendance_number: "41" }, { attendance_number: "abc" },
    { password: "" }, { password_confirmation: "different" }, { password: "a" * 73, password_confirmation: "a" * 73 } ].each do |change|
    it "rejects invalid input #{change.keys.inspect} with Japanese errors and no exposed password" do
      login
      expect { post students_path, params: { student: attributes.merge(change) } }.not_to change(Student, :count)
      expect(response).to have_http_status(422)
      expect(document.at_css("[role='alert']").text).to include("登録できませんでした")
      expect(document.at_css("[role='alert']").text).not_to include("Translation missing", "can't be blank")
      expect(document.at_css("input[name='student[password]']")[:value]).to be_blank
      expect(document.at_css("input[name='student[password_confirmation]']")[:value]).to be_blank
      expect(response.body).not_to include("password123")
    end
  end

  it "rejects duplicate attendance numbers without changing the existing student" do
    existing = Student.create!(classroom: classroom, attendance_number: 1, password: "existing-password")
    original = existing.attributes
    login
    expect { post students_path, params: { student: attributes } }.not_to change(Student, :count)
    expect(response).to have_http_status(422)
    expect(document.at_css("[role='alert']").text).to include("出席番号はすでに登録されています")
    expect(existing.reload.attributes).to eq(original)
  end

  it "handles a database uniqueness race as a registration error" do
    login
    allow_any_instance_of(Student).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)
    expect { post students_path, params: { student: attributes } }.not_to change(Student, :count)
    expect(response).to have_http_status(422)
    expect(document.at_css("[role='alert']").text).to include("出席番号はすでに登録されています")
  end

  [ :other_teacher, :other_school, :inconsistent_school ].each do |kind|
    it "excludes and rejects #{kind} classrooms" do
      target_school = kind == :other_teacher ? school : School.create!(school_code: "FOREIGN")
      owner = kind == :inconsistent_school ? teacher : Teacher.create!(school: target_school, user_id: "other", password: "password123")
      target = Classroom.new(school: target_school, teacher: owner, grade: 2, class_number: 1)
      target.save!(validate: kind != :inconsistent_school) # Historical school mismatch only.
      login
      get new_student_path
      expect(document.css("option").map { |option| option[:value] }).not_to include(target.id.to_s)
      expect { post students_path, params: { student: attributes.merge(classroom_id: target.id.to_s) } }.not_to change(Student, :count)
      expect(response).to have_http_status(:not_found)
    end
  end

  [ "", "1abc", [ "1" ], { id: "1" } ].each do |id|
    it "rejects malformed classroom selection #{id.inspect}" do
      login
      expect { post students_path, params: { student: attributes.merge(classroom_id: id) } }.not_to change(Student, :count)
      expect(response).to have_http_status(422)
    end
  end

  it "ignores forged roles, school IDs, student IDs and password digests" do
    login
    teacher_count = Teacher.count
    post students_path, params: { student: attributes.merge(id: 999999, school_id: 999999,
      teacher_id: teacher.id, role: "teacher", password_digest: "forged", user_id: "forged") }
    expect(response).to redirect_to(new_student_path)
    expect(Student.last.classroom).to eq(classroom)
    expect(Student.last.authenticate("password123")).to be_truthy
    expect(Teacher.count).to eq(teacher_count)
  end

  [ :anonymous, :student ].each do |actor|
    it "rejects #{actor} access to the form and creation" do
      if actor == :student
        Student.create!(classroom: classroom, attendance_number: 2, password: "student-password")
        post student_login_path, params: { student_session: {
          school_code: school.school_code, grade: 1, class_number: 1, attendance_number: 2, password: "student-password"
        } }
      end
      get new_student_path
      expect(response).to redirect_to(login_path)
      expect { post students_path, params: { student: attributes } }.not_to change(Student, :count)
      expect(response).to redirect_to(login_path)
    end
  end

  it "shows guidance when there is no assigned classroom" do
    login
    get new_student_path
    expect(response.body).to include("登録できる担当クラスがありません")
    expect(document.at_css("form[action='#{students_path}']")).to be_nil
  end

  it "requires a CSRF token when creating a student" do
    classroom
    original_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    get login_path
    token = document.at_css("input[name='authenticity_token']")[:value]
    post login_path, params: { authenticity_token: token, session: { user_id: teacher.user_id, password: "password123" } }
    get new_student_path
    token = document.at_css("input[name='authenticity_token']")[:value]
    expect { post students_path, params: { student: attributes } }.not_to change(Student, :count)
    expect(response).to have_http_status(422)
    expect { post students_path, params: { authenticity_token: token, student: attributes } }.to change(Student, :count).by(1)
    expect(response).to redirect_to(new_student_path)
  ensure
    ActionController::Base.allow_forgery_protection = original_protection
  end
  it "registers attendance 40 and exposes the same form limits" do
    classroom
    login
    get new_student_path
    expect(%w[min max].map { |attribute| document.at_css("input[name='student[attendance_number]']")[attribute] }).to eq([ "1", "40" ])
    post students_path, params: { student: attributes.merge(attendance_number: "40") }
    expect(response).to redirect_to(new_student_path)
    expect(Student.last.attendance_number).to eq(40)
  end

  [ { grade: 7 }, { class_number: 16 } ].each do |invalid|
    it "excludes and rejects legacy out-of-range classrooms #{invalid}" do
      target = Classroom.new(school: school, teacher: teacher, grade: 1, class_number: 2, **invalid)
      target.save!(validate: false)
      login
      get new_student_path
      expect(document.css("option").map { |option| option[:value] }).not_to include(target.id.to_s)
      expect { post students_path, params: { student: attributes.merge(classroom_id: target.id.to_s) } }.not_to change(Student, :count)
      expect(response).to have_http_status(:not_found)
    end
  end
end
