require "rails_helper"
require_relative "../../support/ai_grading_context"

RSpec.describe Admin::TeacherRegistration do
  include_context "AI grading records"

  let(:admin) { Admin.create!(school: school, user_id: "registration-admin", password: "synthetic-admin-password") }
  let(:registration) { described_class.new(admin: admin) }
  let(:attributes) { { user_id: "new-teacher", password: "Long River 8 Beacon 42", password_confirmation: "Long River 8 Beacon 42" } }

  it "rejects a common staff password before creating a teacher" do
    expect(registration.call(attributes: attributes.merge(password: "password123456789",
      password_confirmation: "password123456789"))).to be(false)
    expect(registration.teacher.errors[:password]).to be_present
    expect(Teacher.where(school: school)).to be_empty
  end

  def counts
    [ Teacher, Classroom, TeacherClassroom ].map(&:count)
  end

  it "creates only selected classrooms and stores a hashed teacher password" do
    expect(registration.call(attributes: attributes, classroom_codes: [ "1-1", "3-10" ])).to be(true)
    created = registration.teacher.reload

    expect(created.school).to eq(school)
    expect(created.authenticate(attributes[:password])).to eq(created)
    expect(created.password_digest).not_to eq(attributes[:password])
    expect(created.classrooms.pluck(:grade, :class_number)).to match_array([ [ 1, 1 ], [ 3, 10 ] ])
    expect(Classroom.count).to eq(2)
    expect(created.classrooms.pluck(:teacher_id)).to eq([ nil, nil ])
  end

  [ nil, [], [ "" ] ].each do |codes|
    it "allows no assigned classrooms: #{codes.inspect}" do
      expect(registration.call(attributes: attributes, classroom_codes: codes)).to be(true)
      expect(registration.teacher.classrooms).to be_empty
      expect(Classroom.count).to eq(0)
      expect(TeacherClassroom.count).to eq(0)
    end
  end

  it "reuses an existing class without changing its other teachers or attributes" do
    classroom
    existing = [ classroom, teacher, classroom.teacher_classrooms.sole ]
    original = existing.map { |record| record.reload.attributes }

    expect(registration.call(attributes: attributes, classroom_codes: [ "1-1", "2-2" ])).to be(true)
    expect(Classroom.count).to eq(2)
    expect(classroom.reload.teachers).to contain_exactly(teacher, registration.teacher)
    expect(existing.map { |record| record.reload.attributes }).to eq(original)
  end

  it "ignores duplicate checkbox values without duplicating links" do
    expect(registration.call(attributes: attributes, classroom_codes: [ "", "1-1", "1-1" ])).to be(true)
    expect(Classroom.count).to eq(1)
    expect(registration.teacher.teacher_classrooms.count).to eq(1)
  end

  it "rejects globally duplicate teacher IDs and preserves the existing teacher" do
    foreign_school = School.create!(school_code: "FOREIGNREG")
    existing = Teacher.create!(school: foreign_school, user_id: attributes[:user_id], password: "existing-password")
    original = existing.attributes
    before_counts = counts

    expect(registration.call(attributes: attributes, classroom_codes: [ "1-1" ])).to be(false)
    expect(registration.teacher.errors[:user_id]).to be_present
    expect(counts).to eq(before_counts)
    expect(existing.reload.attributes).to eq(original)
  end

  [ { user_id: "" }, { password: "", password_confirmation: "" }, { password_confirmation: nil },
    { password_confirmation: "different" }, { password: "a" * 73, password_confirmation: "a" * 73 } ].each do |change|
    it "rejects invalid credentials without creating classrooms: #{change.keys.inspect}" do
      registration
      before_counts = counts

      expect(registration.call(attributes: attributes.merge(change), classroom_codes: [ "1-1" ])).to be(false)
      expect(registration.teacher.errors).to be_present
      expect(counts).to eq(before_counts)
    end
  end

  [ [ "4-1" ], [ "0-1" ], [ "1-11" ], [ "1-0" ], [ "1-01" ], [ "1-1", "99" ],
    [ 1 ], [ [ "1-1" ] ], { id: "1-1" }, "1-1", false ].each do |codes|
    it "rejects invalid classroom selections before writing: #{codes.inspect}" do
      registration
      before_counts = counts

      expect(registration.call(attributes: attributes, classroom_codes: codes)).to be(false)
      expect(registration.teacher.errors[:base]).to be_present
      expect(counts).to eq(before_counts)
    end
  end

  [ ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotSaved ].each do |error|
    it "rolls back the teacher and both classrooms when the second link fails with #{error}" do
      registration
      before_counts = counts
      allow_any_instance_of(TeacherClassroom).to receive(:save!).and_wrap_original do |method, *args, **kwargs|
        if method.receiver.classroom.class_number == 2
          raise error == ActiveRecord::RecordInvalid ? error.new(method.receiver) : error.new("Injected save failure")
        end
        method.call(*args, **kwargs)
      end

      expect(registration.call(attributes: attributes, classroom_codes: [ "1-1", "1-2" ])).to be(false)
      expect(counts).to eq(before_counts)
      expect(registration.teacher.errors[:base]).to be_present
    end
  end

  it "keeps all existing students, submissions, decisions, PDFs and distribution data unchanged" do
    submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nanswer"), filename: "answer.pdf", content_type: "application/pdf")
    result = submission.grading_results.create!(question: create_question, ai_judgment: :needs_review,
      teacher_judgment: :correct, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    records = [ school, teacher, classroom, student, assignment, assignment.assignment_classrooms.sole, submission, result.question, result,
      classroom.teacher_classrooms.sole, submission.answer_file_attachment, submission.answer_file.blob ]
    original = records.map { |record| record.reload.attributes }
    pdf = submission.answer_file.download

    expect(registration.call(attributes: attributes, classroom_codes: [ "1-1", "2-2" ])).to be(true)
    expect(records.map { |record| record.reload.attributes }).to eq(original)
    expect(submission.answer_file.download).to eq(pdf)
  end
end
