require "rails_helper"

RSpec.describe "Student assignments", type: :request do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:other_classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 2) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "student-password") }

  def login
    post student_login_path, params: { student_session: {
      school_code: school.school_code, grade: classroom.grade, class_number: classroom.class_number,
      attendance_number: student.attendance_number, password: "student-password"
    } }
  end

  def document
    Nokogiri::HTML(response.body)
  end

  def distribute(title, targets: [ classroom ], owner: teacher, filename: "material.pdf", content_type: "application/pdf")
    item = Assignment.create!(teacher: owner, title: title, point_per_question: 5)
    targets.each { |target| item.assignment_classrooms.create!(classroom: target) }
    if filename
      item.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files", filename)),
        filename: filename, content_type: content_type)
    end
    item
  end

  it "lists only classroom assignments, newest first without duplicates, regardless of owner" do
    old = distribute("古い小テスト", targets: [ classroom, other_classroom ])
    old.update!(created_at: 1.day.ago)
    other_teacher = Teacher.create!(school: school, user_id: "teacher2", password: "password123")
    latest = distribute("新しい小テスト", owner: other_teacher)
    distribute("別クラス", targets: [ other_classroom ])
    foreign_school = School.create!(school_code: "OTHER1")
    foreign_class = Classroom.create!(school: foreign_school, teacher: teacher, grade: 1, class_number: 1)
    distribute("別学校", targets: [ foreign_class ])
    distribute("未配信", targets: [])
    login
    get student_assignments_path

    expect(response).to have_http_status(:ok)
    expect(document.at_css("h1").text).to eq("配信された小テスト")
    expect(document.css("li a").map { |link| link[:href] }).to eq([
      student_assignment_path(latest), student_assignment_path(old)
    ])
    expect(document.css("li").map { |node| node.text.strip }).to all(include("詳細"))
    expect(response.body).not_to include("別クラス", "別学校", "未配信")
    expect(document.css("form, button, input")).to be_empty
  end

  it "shows an empty list" do
    login
    get student_assignments_path
    expect(response.body).to include("配信された小テストはありません。")
  end

  it "shows only the approved details and authenticated material links without modifying records" do
    item = distribute("式の計算", targets: [ classroom, other_classroom ])
    before_attributes = item.reload.attributes
    before_links = item.assignment_classrooms.map(&:attributes)
    before_attachments = item.material_file.attachment.attributes
    login
    get student_assignments_path
    get student_assignment_path(item)

    expect(response).to have_http_status(:ok)
    expect(document.css("dt").map(&:text)).to eq([ "タイトル", "1問あたりの点数", "教材ファイル名" ])
    expect(document.css("dd").map(&:text)).to eq([ "式の計算", "5", "material.pdf" ])
    expect(document.css("a").map { |link| link[:href] }).to eq([
      student_assignments_path, material_student_assignment_path(item), material_student_assignment_path(item, download: "1")
    ])
    expect(document.css("form, button, input")).to be_empty
    expect(response.body).not_to include("/rails/active_storage", "再配信", "編集", "削除", "提出")
    get material_student_assignment_path(item)
    expect(item.reload.attributes).to eq(before_attributes)
    expect(item.assignment_classrooms.map(&:attributes)).to eq(before_links)
    expect(item.material_file.attachment.reload.attributes).to eq(before_attachments)
  end

  it "returns the PDF inline with private cache headers, or as a download" do
    item = distribute("教材")
    login
    get material_student_assignment_path(item)
    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
    expect(response.media_type).to eq("application/pdf")
    expect(response.headers["Content-Disposition"]).to include("inline", "material.pdf")
    expect(response.headers["Cache-Control"]).to include("private", "no-store")
    expect(response.headers["X-Content-Type-Options"]).to eq("nosniff")
    get material_student_assignment_path(item, download: "1")
    expect(response.headers["Content-Disposition"]).to include("attachment", "material.pdf")
  end

  it "downloads non-PDF materials instead of opening them inline" do
    item = distribute("テキスト", filename: "material.txt", content_type: "text/plain")
    login
    get student_assignment_path(item)
    expect(response.body).not_to include("教材を開く")
    get material_student_assignment_path(item)
    expect(response.headers["Content-Disposition"]).to include("attachment")
    expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.txt")))
  end

  it "hides links and returns 404 when the attachment is absent" do
    item = distribute("添付なし", filename: nil)
    login
    get student_assignment_path(item)
    expect(response).to have_http_status(:ok)
    expect(document.css("a").map { |link| link[:href] }).to eq([ student_assignments_path ])
    get material_student_assignment_path(item)
    expect(response).to have_http_status(:not_found)
  end

  it "returns 404 for details and material outside the student's classroom" do
    foreign_school = School.create!(school_code: "OTHER1")
    foreign_class = Classroom.create!(school: foreign_school, teacher: teacher, grade: 1, class_number: 1)
    items = [ distribute("別クラス", targets: [ other_classroom ]),
      distribute("別学校", targets: [ foreign_class ]), distribute("未配信", targets: []) ]
    login
    (items.map(&:id) + [ Assignment.maximum(:id) + 100 ]).each do |id|
      [ student_assignment_path(id), material_student_assignment_path(id) ].each do |path|
        get path
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  [ :logged_out, :teacher, :logged_out_after_login, :deleted_student ].each do |authentication|
    it "rejects all student routes when #{authentication}" do
      item = distribute("教材")
      case authentication
      when :teacher
        post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
      when :logged_out_after_login
        login
        delete student_logout_path
      when :deleted_student
        login
        student.destroy!
      end
      [ student_assignments_path, student_assignment_path(item), material_student_assignment_path(item) ].each do |path|
        get path
        expect(response).to have_http_status(:see_other)
        expect(response).to redirect_to(student_login_path)
      end
    end
  end

  it "disables standard Active Storage routes even with valid signed identifiers" do
    item = distribute("教材")
    blob = item.material_file.blob
    signed_id = blob.signed_id
    disk_key = ActiveStorage.verifier.generate({ key: blob.key, disposition: "inline", content_type: blob.content_type,
      service_name: blob.service_name }, purpose: :blob_key, expires_in: 5.minutes)
    variation = ActiveStorage::Variation.wrap(resize_to_limit: [ 100, 100 ]).key
    prefix = "/rails/active_storage"
    paths = [ "#{prefix}/blobs/redirect/#{signed_id}/material.pdf",
      "#{prefix}/blobs/proxy/#{signed_id}/material.pdf", "#{prefix}/blobs/#{signed_id}/material.pdf",
      "#{prefix}/disk/#{disk_key}/material.pdf",
      "#{prefix}/representations/redirect/#{signed_id}/#{variation}/material.pdf",
      "#{prefix}/representations/proxy/#{signed_id}/#{variation}/material.pdf",
      "#{prefix}/representations/#{signed_id}/#{variation}/material.pdf" ]
    expect(Rails.application.config.active_storage.draw_routes).to be(false)
    expect(Rails.application.routes.routes.map { |route| route.defaults[:controller] }.compact.grep(/\Aactive_storage\//)).to be_empty
    paths.each do |path|
      expect { Rails.application.routes.recognize_path(path, method: :get) }.to raise_error(ActionController::RoutingError)
    end
  end

  it "connects teacher distribution, student login, list, details and material" do
    student
    post login_path, params: { session: { user_id: teacher.user_id, password: "password123" } }
    post assignments_path, params: { assignment: { title: "配信教材", point_per_question: "5",
      classroom_ids: [ classroom.id.to_s ],
      material_file: fixture_file_upload(Rails.root.join("spec/fixtures/files/material.pdf"), "application/pdf") } }
    expect(response).to have_http_status(:see_other)
    item = Assignment.last
    login
    expect(response).to redirect_to(student_assignments_path)
    follow_redirect!
    get document.at_css("a[href='#{student_assignment_path(item)}']")[:href]
    expect(response.body).to include("配信教材", "material.pdf")
    get document.at_css("a[href='#{material_student_assignment_path(item)}']")[:href]
    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(File.binread(Rails.root.join("spec/fixtures/files/material.pdf")))
  end
end
