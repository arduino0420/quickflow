require "rails_helper"

RSpec.describe Admin::StudentAccountChange do
  include ActiveSupport::Testing::TimeHelpers
  let(:school) { School.create!(school_code: "ACCOUNTCHANGE") }
  let(:admin) { Admin.create!(school: school, user_id: "change-admin", password: "admin-password") }
  let(:room) { Classroom.create!(school: school, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: room, attendance_number: 1, password: "original-password") }
  let(:editor) { described_class.new(admin: admin, student_id: student.id) }
  let(:teacher) { Teacher.create!(school: school, user_id: "change-teacher", password: "teacher-password") }
  let(:assignment) { Assignment.create!(teacher: teacher, title: "Account safety quiz", point_per_question: 5) }

  def draft
    AnswerDraft.create!(student: student, assignment: assignment, material_fingerprint: "a" * 64,
      page_data: [ { "page_number" => 1, "operations" => [] } ])
  end

  def preview(grade: "1", class_number: "1", attendance_number: "2")
    token = editor.prepare("edit").token
    editor.preview(attributes: { grade: grade, class_number: class_number, attendance_number: attendance_number }, token: token)
  end

  def apply_update
    editor.call(operation: "update", token: editor.token)
  end

  it "changes attendance without replacing identity or deleting learning data" do
    assignment.assignment_classrooms.create!(classroom: room)
    submission = Submission.create!(student: student, assignment: assignment, submitted_at: Time.current)
    question = Question.create!(assignment: assignment, question_label: "1", position: 1, question_text: "1+1", correct_answer: "2",
      grading_rule: "addition", answer_generation_model: "test", answer_generation_prompt_version: "v1", answer_generated_at: Time.current)
    result = GradingResult.create!(submission: submission, question: question, ai_judgment: :correct,
      ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    submission.answer_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/material.pdf")), filename: "answer.pdf", content_type: "application/pdf")
    saved_draft = draft
    before = [ submission.reload.attributes, saved_draft.reload.attributes, student.id, student.password_digest,
      result.reload.attributes, submission.answer_file.blob.download ]
    expect(preview).to be(true)
    expect(apply_update).to be(true)
    expect(student.reload.attendance_number).to eq(2)
    expect([ submission.reload.attributes, saved_draft.reload.attributes, student.id, student.password_digest,
      result.reload.attributes, submission.answer_file.blob.download ]).to eq(before)
  end

  it "moves a student only between undistributed classrooms without history" do
    original_room = room.id
    expect(preview(grade: "2", class_number: "3")).to be(true)
    expect(apply_update).to be(true)
    expect(student.reload.classroom.attributes.slice("school_id", "grade", "class_number")).to eq("school_id" => school.id, "grade" => 2, "class_number" => 3)
    expect(Classroom.exists?(original_room)).to be(true)
  end

  it "rejects duplicate attendance and malformed selections" do
    Student.create!(classroom: room, attendance_number: 2, password: "other-password")
    expect(preview).to be(false)
    [ "0", "41", "1.0", "9" * 100, [ "2" ], { number: "2" } ].each do |value|
      expect(preview(attendance_number: value)).to be(false)
    end
    expect(preview(grade: "7")).to be(false)
    expect(preview(class_number: "16")).to be(false)
    expect(student.reload.attendance_number).to eq(1)
  end

  it "rejects moves with draft history even without current distribution" do
    draft
    expect(preview(grade: "2")).to be(false)
    expect(student.reload.classroom).to eq(room)
  end

  it "rejects moves with submission history even if its distribution has been removed" do
    distribution = assignment.assignment_classrooms.create!(classroom: room)
    Submission.create!(student: student, assignment: assignment, submitted_at: Time.current)
    distribution.destroy!
    expect(preview(grade: "2")).to be(false)
  end

  it "rejects distribution on either source or destination and rechecks at commit" do
    destination = Classroom.create!(school: school, grade: 2, class_number: 1)
    expect(preview(grade: "2")).to be(true)
    assignment.assignment_classrooms.create!(classroom: destination)
    expect(apply_update).to be(false)
    expect(student.reload.classroom).to eq(room)
    expect(preview(grade: "2")).to be(false)
    AssignmentClassroom.where(assignment: assignment).delete_all
    assignment.assignment_classrooms.create!(classroom: room)
    expect(preview(grade: "2")).to be(false)
  end

  it "rechecks history added after the edit confirmation" do
    expect(preview(grade: "2")).to be(true)
    draft
    expect(apply_update).to be(false)
    expect(student.reload.classroom).to eq(room)
  end

  it "rejects tokens for another student, admin, operation, stale state, or expired form" do
    token = editor.prepare("password").token
    other = Student.create!(classroom: room, attendance_number: 2, password: "other-password")
    other_editor = described_class.new(admin: admin, student_id: other.id)
    expect(other_editor.call(operation: "password", token: token, attributes: { password: "1234", password_confirmation: "1234" })).to be(false)
    other_admin = Admin.create!(school: school, user_id: "other-change-admin", password: "other-password")
    expect(described_class.new(admin: other_admin, student_id: student.id).call(operation: "delete", token: token)).to be(false)
    expect(editor.call(operation: "delete", token: token)).to be(false)
    student.update!(attendance_number: 3)
    expect(editor.call(operation: "password", token: token)).to be(false)
    token = editor.prepare("delete").token
    travel 15.minutes + 1.second do
      expect(editor.call(operation: "delete", token: token)).to be(false)
    end
    expect(Student.exists?(student.id)).to be(true)
  end

  it "accepts new random-looking 8-digit passwords using the existing hash and rejects replay" do
    [ "58392047", "72618490" ].each do |password|
      token = editor.prepare("password").token
      expect(editor.call(operation: "password", token: token, attributes: { password: password, password_confirmation: password })).to be(true)
      expect(student.reload.authenticate(password)).to eq(student)
      expect(student.password_digest).not_to eq(password)
      expect(editor.call(operation: "password", token: token, attributes: { password: "other", password_confirmation: "other" })).to be(false)
    end
  end

  it "rejects a predictable numeric reset and retains the old password" do
    original = student.password_digest
    token = editor.prepare("password").token
    expect(editor.call(operation: "password", token: token, attributes: {
      password: "123456789012345", password_confirmation: "123456789012345" })).to be(false)
    expect(student.reload.password_digest).to eq(original)
  end

  it "rejects blank, mismatched and oversized passwords without changing the hash" do
    original = student.password_digest
    [ [ "a\0b", "a\0b" ], [ "", "" ], [ "1234", "4321" ], [ "1234", "" ], [ "あ" * 25, "あ" * 25 ], [ [ "1" ], "1" ] ].each do |password, confirmation|
      token = editor.prepare("password").token
      expect(editor.call(operation: "password", token: token, attributes: { password: password, password_confirmation: confirmation })).to be(false)
      expect(student.reload.password_digest).to eq(original)
    end
  end

  it "deletes exactly the unused student, preserving the school, class and other students" do
    other = Student.create!(classroom: room, attendance_number: 2, password: "other-password")
    token = editor.prepare("delete").token
    expect(editor.call(operation: "delete", token: token)).to be(true)
    expect(Student.exists?(student.id)).to be(false)
    expect(other.reload).to be_persisted
    expect(room.reload).to be_persisted
    expect(school.reload).to be_persisted
  end

  it "refuses deletion when a draft is added after opening the confirmation" do
    token = editor.prepare("delete").token
    saved = draft
    expect(editor.call(operation: "delete", token: token)).to be(false)
    expect(saved.reload).to be_persisted
    expect(student.reload).to be_persisted
  end

  it "refuses deletion for distribution or submissions and never cascades" do
    distribution = assignment.assignment_classrooms.create!(classroom: room)
    token = editor.prepare("delete").token
    expect(editor.call(operation: "delete", token: token)).to be(false)
    submission = Submission.create!(student: student, assignment: assignment, submitted_at: Time.current)
    distribution.destroy!
    token = editor.prepare("delete").token
    expect(editor.call(operation: "delete", token: token)).to be(false)
    expect(submission.reload).to be_persisted
    expect(assignment.reload).to be_persisted
  end

  it "rejects another school's student" do
    foreign = School.create!(school_code: "FOREIGNCHANGE")
    foreign_room = Classroom.create!(school: foreign, grade: 1, class_number: 1)
    other = Student.create!(classroom: foreign_room, attendance_number: 1, password: "other-password")
    expect { described_class.new(admin: admin, student_id: other.id) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "rolls back changes if final revision advancement fails" do
    expect(preview(grade: "2")).to be(true)
    original = student.attributes
    allow(editor.student).to receive(:touch).and_raise(ActiveRecord::RecordNotSaved)
    expect(apply_update).to be(false)
    expect(student.reload.attributes).to eq(original)
    expect(school.classrooms.exists?(grade: 2)).to be(false)
  end

  it "rejects an old confirmation after an attendance value changes away and back at the same frozen time" do
    student
    freeze_time do
      expect(preview(attendance_number: "2")).to be(true)
      expect(apply_update).to be(true)
      old = editor.prepare("delete").token
      expect(preview(attendance_number: "3")).to be(true)
      expect(apply_update).to be(true)
      expect(preview(attendance_number: "2")).to be(true)
      expect(apply_update).to be(true)
      expect(editor.call(operation: "delete", token: old)).to be(false)
      expect(student.reload.attendance_number).to eq(2)
    end
  end
end
