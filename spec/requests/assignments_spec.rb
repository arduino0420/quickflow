require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_change, :change

RSpec.describe "Assignment creation", type: :request do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "student-password") }
  let(:attributes) { { title: "式の計算", point_per_question: "5" } }

  def teacher_login
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
  end

  def student_login
    post student_login_path, params: { student_session: {
      school_code: school.school_code, grade: classroom.grade, class_number: classroom.class_number,
      attendance_number: student.attendance_number, password: "student-password"
    } }
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def upload(filename, content_type)
    fixture_file_upload(Rails.root.join("spec/fixtures/files", filename), content_type)
  end

  it "shows only the approved inputs in a multipart creation form for a teacher" do
    teacher_login
    get new_assignment_path

    expect(response).to have_http_status(:ok)
    expect(document.at_css('form[action="/assignments"][method="post"][enctype="multipart/form-data"]')).to be_present
    expect(document.at_css('input[name="assignment[title]"]')).to be_present
    points = document.at_css('input[name="assignment[point_per_question]"][type="number"]')
    expect(points[:min]).to eq("1")
    expect(points[:step]).to eq("1")
    file = document.at_css('input[name="assignment[material_file]"][type="file"]')
    expect(file).to be_present
    expect(file[:accept]).to be_nil
    expect(file["data-direct-upload-url"]).to be_nil
    %w[teacher_id published_at classroom_ids].each do |field|
      expect(document.at_css("[name^='assignment[#{field}]']")).to be_nil
    end
  end

  it "creates a teacher's assignment without material and returns to an empty form with a notice" do
    teacher_login

    expect do
      post assignments_path, params: { assignment: attributes }
    end.to change(Assignment, :count).by(1)

    assignment = Assignment.last
    expect(assignment.teacher).to eq(teacher)
    expect(assignment.title).to eq("式の計算")
    expect(assignment.point_per_question).to eq(5)
    expect(assignment.material_file).not_to be_attached
    expect(assignment.published_at).to be_nil
    expect(assignment.classrooms).to be_empty
    expect(assignment.questions).to be_empty
    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(new_assignment_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("小テストを登録しました")
    expect(document.at_css('input[name="assignment[title]"]')[:value]).to be_blank
    expect(document.at_css('input[name="assignment[point_per_question]"]')[:value]).to be_blank

    get new_assignment_path
    expect(response.body).not_to include("小テストを登録しました")
  end

  { "material.pdf" => "application/pdf", "material.txt" => "text/plain" }.each do |filename, content_type|
    it "creates an assignment with #{filename}" do
      teacher_login

      expect do
        post assignments_path, params: { assignment: attributes.merge(material_file: upload(filename, content_type)) }
      end.to change(Assignment, :count).by(1)

      expect(response).to have_http_status(:see_other)
      assignment = Assignment.last
      expect(assignment.material_file).to be_attached
      expect(assignment.material_file.filename.to_s).to eq(filename)
      expect(assignment.material_file.download).to eq(File.binread(Rails.root.join("spec/fixtures/files", filename)))
    end
  end

  [ { title: "" }, { point_per_question: "" }, { point_per_question: "0" },
    { point_per_question: "1.5" }, { point_per_question: "abc" } ].each do |invalid_attributes|
    it "renders errors without creating an assignment for #{invalid_attributes.inspect}" do
      teacher_login
      submitted = attributes.merge(invalid_attributes)

      expect do
        post assignments_path, params: { assignment: submitted }
      end.not_to change(Assignment, :count)

      expect(response).to have_http_status(422)
      expect(document.at_css('[role="alert"] li')).to be_present
      expect(document.at_css('input[name="assignment[title]"]')[:value].to_s).to eq(submitted[:title])
      expect(document.at_css('input[name="assignment[point_per_question]"]')[:value].to_s).to eq(submitted[:point_per_question])
      expect(document.at_css('form[action="/assignments"]')).to be_present
    end
  end

  it "does not persist or carry material over after an invalid submission" do
    teacher_login

    expect do
      post assignments_path, params: { assignment: attributes.merge(title: "", material_file: upload("material.pdf", "application/pdf")) }
    end.to not_change(Assignment, :count)
      .and not_change(ActiveStorage::Attachment, :count)
      .and not_change(ActiveStorage::Blob, :count)

    expect(response).to have_http_status(422)
    expect(document.at_css('input[name="assignment[material_file]"][type="file"]')[:value]).to be_blank
    expect(document.at_css('input[name="assignment[material_file]"][type="hidden"]')).to be_nil

    post assignments_path, params: { assignment: attributes }
    expect(response).to have_http_status(:see_other)
    expect(Assignment.last.material_file).not_to be_attached
  end

  it "ignores a forged owner, publication date and distribution classrooms" do
    teacher_login
    other_teacher = Teacher.create!(school: school, user_id: "teacher2", password: "password123")

    expect do
      post assignments_path, params: { assignment: attributes.merge(
        teacher_id: other_teacher.id, published_at: "2026-10-05T09:00:00", classroom_ids: [ classroom.id ]
      ) }
    end.to change(Assignment, :count).by(1)
      .and not_change(AssignmentClassroom, :count)
      .and not_change(Question, :count)

    expect(response).to have_http_status(:see_other)
    assignment = Assignment.last
    expect(assignment.teacher).to eq(teacher)
    expect(assignment.published_at).to be_nil
    expect(assignment.classrooms).to be_empty
  end

  [ :logged_out, :student ].each do |authentication|
    context "when #{authentication}" do
      before { student_login if authentication == :student }

      it "redirects the registration page to teacher login" do
        get new_assignment_path

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(login_path)
      end

      it "rejects creation without persisting the assignment or material" do
        expect do
          post assignments_path, params: { assignment: attributes.merge(material_file: upload("material.pdf", "application/pdf")) }
        end.to not_change(Assignment, :count)
          .and not_change(ActiveStorage::Attachment, :count)
          .and not_change(ActiveStorage::Blob, :count)

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(login_path)
      end
    end
  end
end
