require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "Second-round UI improvements", type: :request do
  include_context "AI grading records"

  def document
    Nokogiri::HTML(response.body)
  end

  def student_login
    post student_login_path, params: { student_session: { school_code: school.school_code,
      grade: classroom.grade, class_number: classroom.class_number,
      attendance_number: student.attendance_number, password: "password123" } }
  end

  def result_for(judgment: :needs_review, teacher_judgment: nil)
    result = submission.grading_results.create!(question: create_question, ai_judgment: judgment,
      teacher_judgment: teacher_judgment, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    submission.update!(status: :completed)
    result
  end

  { nil => "", submitted: "", grading: "", failed: "" }.each do |state, expected|
    it "leaves the list score blank for #{state || 'unsubmitted'} and preserves card status" do
      assignment.assignment_classrooms.create!(classroom: classroom)
      submission.update!(status: state) if state
      student_login
      get student_assignments_path
      row = document.at_css("#assignment_#{assignment.id}")
      expect(row.at_css(".student-card-score").text).to eq(expected)
      expect(row.text).not_to include("—", "暫定")
      expect(row[:class].split.include?("assignment-card--submitted")).to eq(!state.nil?)
    end
  end

  [ [ :needs_review, nil, "0点" ], [ :correct, nil, "5点" ],
    [ :needs_review, :correct, "5点" ], [ :correct, :incorrect, "0点" ] ].each do |judgment, teacher_value, expected|
    it "shows #{expected} for #{judgment}/#{teacher_value} using the existing calculation" do
      result = result_for(judgment: judgment, teacher_judgment: teacher_value)
      before_attributes = [ submission.reload.attributes, result.attributes ]
      student_login
      get student_assignments_path
      expect(document.at_css(".student-card-score").text).to eq(expected)
      expect(response.body).not_to include("（暫定）")
      expect([ submission.reload.attributes, result.reload.attributes ]).to eq(before_attributes)
    end
  end

  it "shows a positive completed score even while other questions need review" do
    result_for(judgment: :correct)
    submission.grading_results.create!(question: create_question(position: 2, label: "2"), ai_judgment: :needs_review,
      ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    student_login
    get student_assignments_path
    expect(document.at_css(".student-card-score").text).to eq("5点")
    expect(response.body).not_to include("暫定")
  end

  it "does not invent zero when completed results are incomplete" do
    submission.update!(status: :completed)
    student_login
    get student_assignments_path
    expect(document.at_css(".student-card-score").text).to eq("")
    expect(submission.reload.score).to be_nil
  end

  it "shows the exact student review message and omits the warning without changing judgments" do
    result = result_for
    original = result.attributes
    student_login
    get student_assignment_path(assignment)
    expect(document.at_css("article").text).to include("教師による確認が必要です。先生に申告してください。")
    expect(response.body).not_to include("必要な場合は", "要確認が残るため、現在の得点は暫定です。", "未確認の問題は加点していません。")
    expect(result.reload.attributes).to eq(original)
  end

  [ :submitted, :grading ].each do |state|
    it "keeps automatic refresh without an action button or obsolete reload hint for #{state}" do
      submission.update!(status: state)
      student_login
      get student_assignment_path(assignment)
      frame = document.at_css("#grading-status")
      expect(frame.at_css("[data-controller='grading-status']")).to be_present
      expect(frame.css("a, button, input[type='submit']")).to be_empty
      expect(frame.text).not_to include("採点結果を見る", "結果を確認する", "10秒")
      expect(frame.text).not_to include("このページを開き直してください。")
    end
  end

  it "renders four native dashboard buttons and a teacher row scoped to each native edit link" do
    admin = Admin.create!(school: school, user_id: "ui-admin", password: "synthetic-admin-password")
    other = Teacher.create!(school: school, user_id: "ui-other-teacher", password: "synthetic-password")
    classroom
    foreign_school = School.create!(school_code: "FOREIGNUI")
    foreign = Teacher.create!(school: foreign_school, user_id: "foreign-ui-teacher", password: "synthetic-password")
    post admin_login_path, params: { admin_session: { user_id: admin.user_id, password: "synthetic-admin-password" } }
    get admin_root_path
    buttons = document.css(".admin-dashboard-actions a.admin-dashboard-action")
    expect(buttons.map(&:text)).to eq([ "教師を新規登録", "生徒を新規登録", "教師一覧", "生徒一覧" ])
    expect(buttons.map { |link| link[:href] }).to eq([ new_admin_teacher_path, new_admin_student_path, admin_teachers_path, admin_students_path ])
    get admin_teachers_path
    rows = document.css(".admin-teacher-list tbody tr")
    expect(rows.size).to eq(2)
    expect(response.body).not_to include(foreign.user_id, foreign_school.school_code)
    [ teacher, other ].each do |target|
      row = rows.find { |item| item.at_css("td").text.strip == target.user_id }
      expect(row[:tabindex]).to eq("0")
      expect(row[:'aria-label']).to eq("#{target.user_id}を編集")
      expect(row[:'data-controller']).to eq("row-navigation")
      expect(row[:'data-action']).to include("click->row-navigation#open", "keydown->row-navigation#openWithKeyboard")
      cells = row.css("td")
      expect(cells.size).to eq(3)
      expect(cells[0].css("a")).to be_empty
      link = cells[2].at_css("a.admin-teacher-edit-link")
      expect(link.text).to eq("編集")
      expect(link[:'data-row-navigation-target']).to eq("link")
      expect(link[:href]).to eq(edit_admin_teacher_path(target))
      expect(row.css("a a, a button")).to be_empty
      get link[:href]
      expect(response).to have_http_status(:ok)
      expect(document.at_css("input[name='teacher[user_id]']")[:value]).to eq(target.user_id)
    end
    get edit_admin_teacher_path(foreign)
    expect(response).to have_http_status(:not_found)
  end
end
