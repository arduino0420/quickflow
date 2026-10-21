require "rails_helper"
require_relative "../../support/ai_grading_context"

RSpec.describe Admin::StudentRegistration do
  include_context "AI grading records"
  let(:admin) { Admin.create!(school: school, user_id: "student-admin", password: "synthetic-admin-password") }
  let(:registration) { described_class.new(admin: admin) }
  let(:attributes) { { grade: "1", class_number: "1", attendance_number: "1", password: "739162840517294", password_confirmation: "739162840517294" } }

  def counts
    [ School, Teacher, Classroom, TeacherClassroom, Student ].map(&:count)
  end

  it "creates only the selected classroom and hashes the password without assigning teachers" do
    expect(registration.call(attributes: attributes.merge(grade: "3", class_number: "10", attendance_number: "40"))).to be(true)
    pupil = registration.student.reload
    expect([ pupil.classroom.school, pupil.classroom.grade, pupil.classroom.class_number, pupil.attendance_number ]).to eq([ school, 3, 10, 40 ])
    expect(pupil.authenticate(attributes[:password])).to eq(pupil)
    expect(pupil.password_digest).not_to eq(attributes[:password])
    expect(Classroom.count).to eq(1)
    expect(TeacherClassroom.count).to eq(0)
  end

  it "rejects a predictable 15-digit password before creating a student" do
    expect(registration.call(attributes: attributes.merge(password: "123456789012345",
      password_confirmation: "123456789012345"))).to be(false)
    expect(registration.student.errors[:password]).to be_present
    expect(Student.count).to eq(0)
  end

  it "reuses the existing classroom without changing its data or teachers" do
    classroom
    original = [ classroom.attributes, teacher.attributes, classroom.teacher_classrooms.sole.attributes ]
    expect(registration.call(attributes: attributes)).to be(true)
    expect(registration.student.classroom).to eq(classroom)
    expect(Classroom.count).to eq(1)
    expect([ classroom.reload.attributes, teacher.reload.attributes, classroom.teacher_classrooms.sole.attributes ]).to eq(original)
  end

  it "rejects a duplicate attendance number without overwriting the existing student" do
    student
    original = student.attributes
    registration
    before_counts = counts
    expect(registration.call(attributes: attributes)).to be(false)
    expect(registration.student.errors[:attendance_number]).to be_present
    expect(counts).to eq(before_counts)
    expect(student.reload.attributes).to eq(original)
  end

  { grade: [ nil, "", "0", "4", "01", "a" * 40, [ "1" ] ], class_number: [ "0", "11", "1.5", {} ],
    attendance_number: [ "0", "41", "1abc", "1" * 40 ] }.each do |field, values|
    values.each do |value|
      it "rejects invalid #{field}: #{value.inspect} before creating a class" do
        registration
        before_counts = counts
        expect(registration.call(attributes: attributes.merge(field => value))).to be(false)
        expect(registration.student.errors).to be_present
        expect(counts).to eq(before_counts)
      end
    end
  end

  [ { password: "", password_confirmation: "" }, { password_confirmation: "different" }, { password_confirmation: nil },
    { password_confirmation: "" }, { password: "a" * 73, password_confirmation: "a" * 73 } ].each do |change|
    it "rejects invalid passwords and rolls back newly created classrooms: #{change.keys}" do
      registration
      before_counts = counts
      expect(registration.call(attributes: attributes.merge(change))).to be(false)
      expect(counts).to eq(before_counts)
    end
  end

  [ ActiveRecord::RecordNotUnique, ActiveRecord::RecordNotSaved ].each do |error|
    it "rolls back classroom creation when saving the student raises #{error}" do
      registration
      before_counts = counts
      allow_any_instance_of(Student).to receive(:save!).and_raise(error, "Injected error")
      expect(registration.call(attributes: attributes)).to be(false)
      expect(counts).to eq(before_counts)
      expect(registration.student.errors[:base]).to be_present
    end
  end

  it "never adopts a supplied school, classroom, ID or password digest" do
    foreign_school = School.create!(school_code: "FOREIGNPUPIL")
    foreign = Classroom.create!(school: foreign_school, grade: 1, class_number: 1)
    expect(registration.call(attributes: attributes.merge(school_id: foreign_school.id, classroom_id: foreign.id, id: 123, password_digest: "forged"))).to be(true)
    expect(registration.student.classroom.school).to eq(school)
    expect(registration.student.password_digest).not_to eq("forged")
    expect(foreign.reload.students).to be_empty
  end

  it "preserves existing submissions, PDFs, judgments and assignment ownership" do
    submission.answer_file.attach(io: StringIO.new("%PDF-1.4\nanswer"), filename: "answer.pdf", content_type: "application/pdf")
    result = submission.grading_results.create!(question: create_question, ai_judgment: :needs_review,
      teacher_judgment: :correct, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    records = [ school, teacher, classroom, classroom.teacher_classrooms.sole, student, assignment,
      assignment.assignment_classrooms.sole, submission, result.question, result, submission.answer_file_attachment, submission.answer_file.blob ]
    original = records.map { |record| record.reload.attributes }
    pdf = submission.answer_file.download
    expect(registration.call(attributes: attributes.merge(attendance_number: "2"))).to be(true)
    expect(records.map { |record| record.reload.attributes }).to eq(original)
    expect(submission.answer_file.download).to eq(pdf)
  end
end
