require "rails_helper"
require_relative "../../support/ai_grading_context"

RSpec.describe Admin::TeacherUpdate do
  include_context "AI grading records"
  include ActiveSupport::Testing::TimeHelpers

  let(:admin) { Admin.create!(school: school, user_id: "edit-admin", password: "synthetic-admin-password") }
  let(:editor) { described_class.new(admin: admin, teacher_id: teacher.id) }
  let(:token) { editor.prepare.edit_token }

  def update(codes: [ "1-1" ], attributes: {}, edit_token: token)
    editor.call(attributes: attributes, classroom_codes: codes, edit_token: edit_token)
  end

  def counts
    [ Teacher, Classroom, TeacherClassroom ].map(&:count)
  end

  it "reuses a shared classroom, creates only selected classes and removes relationships only" do
    classroom
    other = Teacher.create!(school: school, user_id: "other-editor", password: "other-password")
    shared = Classroom.create!(school: school, grade: 2, class_number: 2, teachers: [ other ])
    original = [ classroom.attributes, other.attributes, shared.teacher_classrooms.sole.attributes ]

    expect(update(codes: [ "2-2", "3-10", "3-10" ])).to be(true)
    expect(teacher.reload.classrooms.pluck(:grade, :class_number)).to match_array([ [ 2, 2 ], [ 3, 10 ] ])
    expect(classroom.reload.teachers).to be_empty
    expect(shared.reload.teachers).to contain_exactly(other, teacher)
    expect([ classroom.attributes, other.reload.attributes, other.teacher_classrooms.sole.attributes ]).to eq(original)
    expect(Classroom.count).to eq(3)
  end

  it "allows removing every assignment without deleting classrooms" do
    classroom
    expect(update(codes: [ "" ])).to be(true)
    expect(teacher.reload.classrooms).to be_empty
    expect(classroom.reload).to be_persisted
  end

  it "keeps the password digest when password is blank even if confirmation is supplied" do
    original = teacher.password_digest
    expect(update(attributes: { password: "", password_confirmation: "ignored" })).to be(true)
    expect(teacher.reload.password_digest).to eq(original)
  end

  it "changes only the password when supplied with matching confirmation" do
    expect(update(attributes: { password: "Long River 8 Beacon 42", password_confirmation: "Long River 8 Beacon 42" })).to be(true)
    expect(teacher.reload.authenticate("Long River 8 Beacon 42")).to eq(teacher)
    expect(teacher.authenticate("password123")).to be(false)
  end

  [ { password: "new-password", password_confirmation: "wrong" },
    { password: "new-password", password_confirmation: "" }, { password: "new-password" },
    { password: "a" * 73, password_confirmation: "a" * 73 } ].each do |attributes|
    it "rejects invalid password input #{attributes.keys}" do
      original = teacher.attributes
      expect(update(codes: [ "3-10" ], attributes: attributes)).to be(false)
      expect(teacher.reload.attributes).to eq(original)
      expect(Classroom.count).to eq(0)
    end
  end

  [ [ "4-1" ], [ "1-11" ], [ "1-01" ], "1-1", { id: "1-1" }, [ 1 ] ].each do |codes|
    it "rejects malformed class selections #{codes.inspect}" do
      classroom
      original = counts
      expect(update(codes: codes)).to be(false)
      expect(counts).to eq(original)
      expect(classroom.reload.teachers).to contain_exactly(teacher)
    end
  end

  [ nil, "", "tampered" ].each do |invalid|
    it "rejects missing or tampered edit tokens #{invalid.inspect}" do
      original = teacher.attributes
      expect(update(edit_token: invalid)).to be(false)
      expect(teacher.reload.attributes).to eq(original)
      expect(Classroom.count).to eq(0)
    end
  end

  it "rejects a token issued for a different teacher" do
    other = Teacher.create!(school: school, user_id: "other-edit", password: "other-password")
    other_token = described_class.new(admin: admin, teacher_id: other.id).prepare.edit_token
    expect(update(edit_token: other_token)).to be(false)
  end

  it "rejects a token issued to another administrator" do
    other_admin = Admin.create!(school: school, user_id: "other-admin", password: "other-password")
    other_token = described_class.new(admin: other_admin, teacher_id: teacher.id).prepare.edit_token
    expect(update(edit_token: other_token)).to be(false)
  end

  it "rejects a stale token even after a no-op update at a frozen time" do
    travel_to(Time.current) do
      original_token = token
      expect(update(codes: [], edit_token: original_token)).to be(true)
      saved = teacher.reload.attributes
      expect(update(codes: [ "3-10" ], edit_token: original_token)).to be(false)
      expect(teacher.reload.attributes).to eq(saved)
      expect(Classroom.count).to eq(0)
    end
  end

  it "detects relationships changed without touching the teacher" do
    original_token = token
    classroom
    expect(update(codes: [], edit_token: original_token)).to be(false)
    expect(classroom.reload.teachers).to contain_exactly(teacher)
  end

  it "detects changes to assigned classroom attributes" do
    classroom
    original_token = token
    classroom.update!(class_number: 2)
    expect(update(codes: [], edit_token: original_token)).to be(false)
  end

  it "rejects an existing class outside the 30 displayed options without deleting it" do
    outside = Classroom.create!(school: school, grade: 4, class_number: 1, teachers: [ teacher ])
    expect(update(codes: [])).to be(false)
    expect(editor.teacher.errors[:base].join).to include("表示範囲外")
    expect(outside.reload.teachers).to contain_exactly(teacher)
  end

  it "rejects historical cross-school assignments rather than deleting them" do
    foreign_school = School.create!(school_code: "FOREIGNEDIT")
    foreign = Classroom.create!(school: foreign_school, grade: 1, class_number: 1)
    relationship = TeacherClassroom.new(teacher: teacher, classroom: foreign)
    relationship.save!(validate: false)
    expect(update(codes: [])).to be(false)
    expect(relationship.reload).to be_persisted
  end

  [ ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique ].each do |error|
    it "rolls back password and class creation when adding a relationship fails with #{error}" do
      classroom
      original = teacher.attributes
      original_counts = counts
      allow_any_instance_of(TeacherClassroom).to receive(:save!).and_wrap_original do |method, *args, **kwargs|
        if method.receiver.classroom.grade == 3
          raise error == ActiveRecord::RecordInvalid ? error.new(method.receiver) : error.new("Injected error")
        end
        method.call(*args, **kwargs)
      end
      expect(update(codes: [ "2-2", "3-10" ], attributes: { password: "new-password", password_confirmation: "new-password" })).to be(false)
      expect(counts).to eq(original_counts)
      expect(teacher.reload.attributes).to eq(original)
      expect(classroom.reload.teachers).to contain_exactly(teacher)
    end
  end

  it "rolls back removed relationships and password if the final revision update fails" do
    classroom
    original = teacher.attributes
    link = teacher.teacher_classrooms.sole.attributes
    allow_any_instance_of(Teacher).to receive(:touch).and_raise(ActiveRecord::RecordNotSaved, "Injected failure")
    expect(update(codes: [], attributes: { password: "new-password", password_confirmation: "new-password" })).to be(false)
    expect(teacher.reload.attributes).to eq(original)
    expect(teacher.teacher_classrooms.sole.attributes).to eq(link)
  end

  it "preserves all existing data, ownership, PDFs and judgments when removing the teacher relationship" do
    submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nanswer"), filename: "answer.pdf", content_type: "application/pdf")
    result = submission.grading_results.create!(question: create_question, ai_judgment: :needs_review,
      teacher_judgment: :correct, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    records = [ school, classroom, student, assignment, assignment.assignment_classrooms.sole, submission, result.question, result,
      submission.answer_file_attachment, submission.answer_file.blob ]
    original = records.map { |record| record.reload.attributes }
    pdf = submission.answer_file.download
    expect(update(codes: [])).to be(true)
    expect(records.map { |record| record.reload.attributes }).to eq(original)
    expect(submission.answer_file.download).to eq(pdf)
    expect(teacher.reload.assignments).to include(assignment)
  end
end
