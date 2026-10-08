require "rails_helper"

RSpec::Matchers.define_negated_matcher :not_change, :change

RSpec.describe "Assignment creation", type: :request do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "student-password") }
  let(:attributes) { { title: "式の計算", point_per_question: "5",
    material_file: upload("material.pdf", "application/pdf"), classroom_ids: [ classroom.id.to_s ] } }

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
    expect(document.at_css("h1").text).to eq("小テスト配信")
    expect(document.at_css("a[href='/assignments']").text).to eq("配信済み小テスト")
    expect(document.at_css("a[href*='/distribution']")).to be_nil
    expect(document.at_css('form[action="/assignments"][method="post"][enctype="multipart/form-data"]')).to be_present
    expect(document.at_css('input[name="assignment[title]"]')).to be_present
    points = document.at_css('input[name="assignment[point_per_question]"][type="number"]')
    expect(points[:min]).to eq("1")
    expect(points[:step]).to eq("1")
    file = document.at_css('input[name="assignment[material_file]"][type="file"]')
    expect(file).to be_present
    expect(file[:accept]).to be_nil
    expect(file["data-direct-upload-url"]).to be_nil
    %w[teacher_id published_at].each do |field|
      expect(document.at_css("[name^='assignment[#{field}]']")).to be_nil
    end
  end

  it "creates and distributes a teacher's assignment and returns to an empty form with a notice" do
    teacher_login
    expect(QuestionGenerator).not_to receive(:new)

    expect do
      post assignments_path, params: { assignment: attributes }
    end.to change(Assignment, :count).by(1)
      .and change(AssignmentClassroom, :count).by(1)

    assignment = Assignment.last
    expect(assignment.teacher).to eq(teacher)
    expect(assignment.title).to eq("式の計算")
    expect(assignment.point_per_question).to eq(5)
    expect(assignment.material_file).to be_attached
    expect(assignment.published_at).to be_nil
    expect(assignment.classrooms).to contain_exactly(classroom)
    expect(assignment.questions).to be_empty
    expect(QuestionGenerationJob).to have_been_enqueued.with(assignment, assignment.material_file.blob.id).exactly(:once)
    expect(response).to have_http_status(:see_other)
    expect(response).to redirect_to(new_assignment_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("小テストを配信しました")
    expect(document.at_css('input[name="assignment[title]"]')[:value]).to be_blank
    expect(document.at_css('input[name="assignment[point_per_question]"]')[:value]).to be_blank

    get new_assignment_path
    expect(response.body).not_to include("小テストを配信しました")
  end

  context "when question generation cannot be enqueued" do
    around do |example|
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rails.cache = original_cache
    end

    [ :exception, :rejected ].each do |failure|
      it "keeps distribution successful and records a #{failure} enqueue failure" do
        teacher_login
        if failure == :exception
          allow(QuestionGenerationJob).to receive(:perform_later).and_raise("Queue unavailable")
        else
          allow(QuestionGenerationJob).to receive(:perform_later).and_return(false)
        end
        allow(Rails.logger).to receive(:error)
        expect { post assignments_path, params: { assignment: attributes } }.to change(Assignment, :count).by(1)
        expect(response).to have_http_status(:see_other)
        assignment = Assignment.last
        expect(assignment.classrooms).to contain_exactly(classroom)
        expect(QuestionGenerator.new.failed?(assignment)).to be(true)
        expect(Rails.logger).to have_received(:error).with(/Question generation enqueue failed/).once
      end
    end
  end

  { "material.pdf" => "application/pdf", "material.txt" => "text/plain" }.each do |filename, content_type|
    it "creates an assignment with #{filename}" do
      teacher_login

      expect do
        post assignments_path, params: { assignment: attributes.merge(material_file: upload(filename, content_type)) }
      end.to change(Assignment, :count).by(1)
      .and change(AssignmentClassroom, :count).by(1)

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
      end.to not_change(Assignment, :count)
        .and not_change(AssignmentClassroom, :count)

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
      .and not_change(AssignmentClassroom, :count)
      .and not_change(ActiveStorage::Attachment, :count)
      .and not_change(ActiveStorage::Blob, :count)

    expect(response).to have_http_status(422)
    expect(document.at_css('input[name="assignment[material_file]"][type="file"]')[:value]).to be_blank
    expect(document.at_css('input[name="assignment[material_file]"][type="hidden"]')).to be_nil

    post assignments_path, params: { assignment: attributes.except(:material_file) }
    expect(response).to have_http_status(422)
    expect(Assignment.count).to eq(0)

    post assignments_path, params: { assignment: attributes.merge(material_file: upload("material.pdf", "application/pdf")) }
    expect(response).to have_http_status(:see_other)
    expect(Assignment.last.material_file).to be_attached
  end

  it "ignores a forged owner and publication date while distributing to validated classrooms" do
    teacher_login
    other_teacher = Teacher.create!(school: school, user_id: "teacher2", password: "password123")

    expect do
      post assignments_path, params: { assignment: attributes.merge(
        teacher_id: other_teacher.id, published_at: "2026-10-05T09:00:00", classroom_ids: [ classroom.id ]
      ) }
    end.to change(Assignment, :count).by(1)
      .and change(AssignmentClassroom, :count).by(1)
      .and not_change(Question, :count)

    expect(response).to have_http_status(:see_other)
    assignment = Assignment.last
    expect(assignment.teacher).to eq(teacher)
    expect(assignment.published_at).to be_nil
    expect(assignment.classrooms).to contain_exactly(classroom)
  end

  context "viewing distributed assignments" do
    let(:distributed) do
      item = Assignment.create!(teacher: teacher, title: "閲覧用小テスト", point_per_question: 7)
      AssignmentClassroom.create!(assignment: item, classroom: classroom)
      item
    end

    before { teacher_login }

    it "lists only owned assignments with distribution links, newest first and without duplicate rows" do
      older = distributed
      older.update!(created_at: 2.days.ago)
      newer = Assignment.create!(teacher: teacher, title: "新しい小テスト", point_per_question: 5)
      second_classroom = Classroom.create!(school: school, teacher: teacher, grade: 2, class_number: 1)
      [ classroom, second_classroom ].each { |item| AssignmentClassroom.create!(assignment: newer, classroom: item) }
      undistributed = Assignment.create!(teacher: teacher, title: "未配信", point_per_question: 5)
      other_teacher = Teacher.create!(school: school, user_id: "teacher2", password: "password123")
      foreign = Assignment.create!(teacher: other_teacher, title: "他教師", point_per_question: 5)
      AssignmentClassroom.create!(assignment: foreign, classroom: classroom)

      get assignments_path
      expect(response).to have_http_status(:ok)
      links = document.css("li a")
      expect(links.map { |link| link[:href] }).to eq([ assignment_path(newer), assignment_path(older) ])
      expect(links.map(&:text)).to eq([ "詳細", "詳細" ])
      expect(response.body).not_to include(undistributed.title, foreign.title)
      expect(document.at_css("a[href='#{new_assignment_path}']").text).to eq("小テスト配信")
      expect(document.css("form")).to be_empty
    end

    it "uses descending ID to order assignments created at the same time" do
      first = distributed
      second = Assignment.create!(teacher: teacher, title: "同時刻", point_per_question: 5, created_at: first.created_at)
      AssignmentClassroom.create!(assignment: second, classroom: classroom)
      get assignments_path
      expect(document.css("li a").map { |link| link[:href] }).to eq([ assignment_path(second), assignment_path(first) ])
    end

    it "shows an empty list when the teacher has only undistributed assignments" do
      Assignment.create!(teacher: teacher, title: "未配信", point_per_question: 5)
      get assignments_path
      expect(response.body).to include("配信済みの小テストはありません。")
    end

    it "shows exactly the approved fields and classes in grade and class order without modifying records" do
      item = distributed
      second = Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 2)
      third = Classroom.create!(school: school, teacher: teacher, grade: 2, class_number: 1)
      [ third, second ].each { |target| AssignmentClassroom.create!(assignment: item, classroom: target) }
      item.material_file.attach(upload("material.pdf", "application/pdf"))
      before_attributes = item.reload.attributes
      before_links = item.assignment_classrooms.order(:id).map(&:attributes)

      expect do
        get assignments_path
        get assignment_path(item)
      end.to not_change(Assignment, :count).and not_change(AssignmentClassroom, :count)
      expect(response).to have_http_status(:ok)
      expect(document.css("dt").map(&:text)).to eq([ "タイトル", "1問あたりの点数", "配信先クラス", "教材ファイル名" ])
      expect(document.css("dd").map { |node| node.text.strip }).to include(item.title, "7", "material.pdf")
      expect(document.css("dd li").map(&:text)).to eq([ "1年1組", "1年2組", "2年1組" ])
      expect(document.css("a").map { |link| [ link.text, link[:href] ] }).to eq([ [ "配信済み小テスト", assignments_path ] ])
      expect(document.css("form, button, input")).to be_empty
      expect(item.reload.attributes).to eq(before_attributes)
      expect(item.assignment_classrooms.order(:id).map(&:attributes)).to eq(before_links)
    end

    it "returns 404 for another teacher, an undistributed assignment and a nonexistent assignment" do
      other_teacher = Teacher.create!(school: school, user_id: "teacher2", password: "password123")
      foreign = Assignment.create!(teacher: other_teacher, title: "他教師", point_per_question: 5)
      AssignmentClassroom.create!(assignment: foreign, classroom: classroom)
      undistributed = Assignment.create!(teacher: teacher, title: "未配信", point_per_question: 5)
      [ foreign.id, undistributed.id, Assignment.maximum(:id) + 100 ].each do |id|
        get assignment_path(id)
        expect(response).to have_http_status(:not_found)
      end
    end

    it "connects initial distribution to the list and read-only details" do
      post assignments_path, params: { assignment: attributes }
      expect(response).to have_http_status(:see_other)
      item = Assignment.last
      follow_redirect!
      get document.at_css("a[href='#{assignments_path}']")[:href]
      expect(response).to have_http_status(:ok)
      get document.at_css("a[href='#{assignment_path(item)}']")[:href]
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(item.title, "material.pdf", "1年1組")
      expect(document.css("form")).to be_empty
    end
  end

  context "initial distribution" do
    let(:other_teacher) { Teacher.create!(school: school, user_id: "teacher2", password: "password123") }
    let(:other_classroom) { Classroom.create!(school: school, teacher: other_teacher, grade: 2, class_number: 1) }
    let(:foreign_school) { School.create!(school_code: "OTHER1") }
    let(:foreign_classroom) { Classroom.create!(school: foreign_school, teacher: other_teacher, grade: 1, class_number: 1) }

    before { teacher_login }

    def expect_no_creation(submitted, encoding: nil)
      expect do
        post assignments_path, params: { assignment: submitted }, as: encoding, headers: { "ACCEPT" => "text/html" }
      end.to not_change(Assignment, :count)
        .and not_change(AssignmentClassroom, :count)
        .and not_change(ActiveStorage::Attachment, :count)
        .and not_change(ActiveStorage::Blob, :count)
      expect(response).to have_http_status(422)
      expect(document.at_css('[role="alert"] li')).to be_present
      expect(document.at_css('form[action="/assignments"][method="post"]')).to be_present
      expect(QuestionGenerationJob).not_to have_been_enqueued
    end

    it "shows only school classrooms in grade order and a distribution button" do
      foreign_classroom
      other_classroom
      classroom
      get new_assignment_path
      boxes = document.css('input[type="checkbox"][name="assignment[classroom_ids][]"]')
      expect(boxes.map { |box| box[:value] }).to eq([ classroom.id.to_s, other_classroom.id.to_s ])
      expect(document.at_css('input[type="submit"]')[:value]).to eq("配信")
      expect(response.body).to include("教材ファイル（必須）", "1年1組", "2年1組")
    end

    it "creates an assignment and multiple unique links including another teacher's classroom" do
      expect do
        post assignments_path, params: { assignment: attributes.merge(
          classroom_ids: [ "", classroom.id.to_s, other_classroom.id.to_s, classroom.id.to_s ]
        ) }
      end.to change(Assignment, :count).by(1)
        .and change(AssignmentClassroom, :count).by(2)
      expect(response).to have_http_status(:see_other)
      expect(Assignment.last.classrooms).to contain_exactly(classroom, other_classroom)
      expect(QuestionGenerationJob).to have_been_enqueued.with(Assignment.last, Assignment.last.material_file.blob.id).exactly(:once)
    end

    it "requires material without changing model validations" do
      expect_no_creation(attributes.except(:material_file))
      expect(response.body).to include("を選択してください")
      expect(document.at_css("input[type='checkbox'][value='#{classroom.id}']")[:checked]).to be_present
    end

    [ nil, [], [ "" ], "1", { "id" => "1" } ].each do |ids|
      it "rejects an absent or malformed selection #{ids.inspect}" do
        expect_no_creation(attributes.merge(classroom_ids: ids))
      end
    end

    it "rejects an omitted classroom_ids parameter" do
      expect_no_creation(attributes.except(:classroom_ids))
    end

    it "rejects a foreign classroom mixed with a valid classroom and retains the valid selection" do
      expect_no_creation(attributes.merge(classroom_ids: [ classroom.id.to_s, foreign_classroom.id.to_s ]))
      expect(document.at_css("input[type='checkbox'][value='#{classroom.id}']")[:checked]).to be_present
      expect(document.at_css("input[type='checkbox'][value='#{foreign_classroom.id}']")).to be_nil
    end

    it "rejects a nonexistent classroom mixed with a valid classroom" do
      missing_id = classroom.id + 100
      expect_no_creation(attributes.merge(classroom_ids: [ classroom.id.to_s, missing_id.to_s ]))
    end

    [ "abc", "0", "-1", "1.5", "1abc", " 1", "01", "999999999999999999999999999999" ].each do |invalid_id|
      it "rejects an invalid ID #{invalid_id.inspect} mixed with a valid classroom" do
        expect_no_creation(attributes.merge(classroom_ids: [ classroom.id.to_s, invalid_id ]))
      end
    end

    it "rejects a nested object ID instead of silently dropping it" do
      # rack-test cannot encode mixed strings and hashes in a multipart array.
      expect_no_creation(attributes.except(:material_file).merge(
        classroom_ids: [ classroom.id.to_s, { "id" => "1" } ]
      ), encoding: :json)
      expect(response.body).to include("配信先クラスを正しく選択してください")
    end

    it "rolls back the assignment, earlier links and attachment records after a later link fails, then allows resubmission" do
      first_classroom = classroom
      second_classroom = other_classroom
      attempted_classroom_ids = []
      allow_any_instance_of(Assignment).to receive(:assignment_classrooms).and_wrap_original do |original|
        association = original.call
        allow(association).to receive(:create!).and_wrap_original do |create, **options|
          attempted_classroom_ids << options[:classroom].id
          if options[:classroom] == second_classroom
            raise ActiveRecord::RecordInvalid.new(AssignmentClassroom.new)
          end
          create.call(**options)
        end
        association
      end

      expect_no_creation(attributes.merge(classroom_ids: [ first_classroom.id.to_s, second_classroom.id.to_s ]))
      expect(attempted_classroom_ids).to eq([ first_classroom.id, second_classroom.id ])
      expect(response.body).to include("配信先を保存できませんでした")
      expect(document.at_css('input[name="assignment[title]"]')[:value]).to eq(attributes[:title])
      expect(document.at_css('input[name="assignment[material_file]"][type="file"]')[:value]).to be_blank
      expect(document.at_css('input[name="assignment[material_file]"][type="hidden"]')).to be_nil
      [ first_classroom, second_classroom ].each do |item|
        expect(document.at_css("input[type='checkbox'][value='#{item.id}']")[:checked]).to be_present
      end

      allow_any_instance_of(Assignment).to receive(:assignment_classrooms).and_call_original
      post assignments_path, params: { assignment: attributes.merge(material_file: upload("material.pdf", "application/pdf")) }
      expect(response).to have_http_status(:see_other)
      expect(Assignment.last.classrooms).to contain_exactly(first_classroom)
    end
  end

  [ :logged_out, :student ].each do |authentication|
    context "when #{authentication}" do
      before { student_login if authentication == :student }

      it "redirects list and detail requests to teacher login" do
        item = Assignment.create!(teacher: teacher, title: "配信済み", point_per_question: 5)
        AssignmentClassroom.create!(assignment: item, classroom: classroom)
        [ assignments_path, assignment_path(item) ].each do |path|
          get path
          expect(response).to have_http_status(:see_other)
          expect(response).to redirect_to(login_path)
        end
      end

      it "redirects the registration page to teacher login" do
        get new_assignment_path

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(login_path)
      end

      it "rejects creation without persisting the assignment or material" do
        expect do
          post assignments_path, params: { assignment: attributes.merge(material_file: upload("material.pdf", "application/pdf")) }
        end.to not_change(Assignment, :count)
          .and not_change(AssignmentClassroom, :count)
          .and not_change(ActiveStorage::Attachment, :count)
          .and not_change(ActiveStorage::Blob, :count)

        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(login_path)
      end
    end
  end
end
