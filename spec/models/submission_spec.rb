require "rails_helper"

RSpec.describe Submission, type: :model do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  let(:assignment) { Assignment.create!(teacher: teacher, title: "Quiz", point_per_question: 5) }
  let(:attributes) { { assignment: assignment, student: student, submitted_at: Time.zone.local(2026, 10, 2, 9) } }

  it "persists its associations and submitted date without an answer file" do
    submission = described_class.create!(attributes).reload

    expect(submission.assignment).to eq(assignment)
    expect(submission.student).to eq(student)
    expect(submission.submitted_at).to eq(attributes[:submitted_at])
    expect(submission.answer_file).not_to be_attached
  end

  [ :assignment, :student, :submitted_at, :status ].each do |attribute|
    it "requires #{attribute}" do
      submission = described_class.new(attributes.merge(attribute => nil))

      expect(submission).not_to be_valid
      expect(submission.errors[attribute]).to be_present
    end
  end

  it "defaults to submitted and stores zero" do
    submission = described_class.new(attributes)

    expect(submission).to be_submitted
    submission.save!
    expect(submission.reload).to be_submitted
    expect(submission.status_before_type_cast).to eq(0)
    expect(described_class.columns_hash.fetch("status").default).to eq("0")
  end

  it "maps the four enum states" do
    expect(described_class.statuses).to eq("submitted" => 0, "grading" => 1, "completed" => 2, "failed" => 3)
  end

  { submitted: 0, grading: 1, completed: 2, failed: 3 }.each do |status, value|
    it "persists #{status} as #{value}" do
      submission = described_class.create!(attributes.merge(status: status)).reload

      expect(submission.status).to eq(status.to_s)
      expect(submission.status_before_type_cast).to eq(value)
    end
  end

  [ "unknown", 4 ].each do |status|
    it "rejects undefined status #{status.inspect}" do
      expect do
        described_class.new(attributes.merge(status: status))
      end.to raise_error(ArgumentError)
    end
  end

  it "rejects duplicate assignment and student pairs" do
    described_class.create!(attributes)
    duplicate = described_class.new(attributes)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:student_id]).to be_present
  end

  it "allows another student for the same assignment" do
    described_class.create!(attributes)
    other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")

    expect(described_class.create!(attributes.merge(student: other_student))).to be_persisted
  end

  it "allows another assignment for the same student" do
    described_class.create!(attributes)
    other_assignment = Assignment.create!(teacher: teacher, title: "Another quiz", point_per_question: 5)

    expect(described_class.create!(attributes.merge(assignment: other_assignment))).to be_persisted
  end

  { "material.pdf" => "application/pdf", "material.txt" => "text/plain" }.each do |filename, content_type|
    it "stores and retrieves #{filename} as the answer" do
      submission = described_class.create!(attributes)
      path = Rails.root.join("spec/fixtures/files", filename)
      File.open(path, "rb") do |file|
        submission.answer_file.attach(io: file, filename: filename, content_type: content_type)
      end

      submission.reload
      expect(submission.answer_file).to be_attached
      expect(submission.answer_file.filename.to_s).to eq(filename)
      expect(submission.answer_file.download).to eq(File.binread(path))
    end
  end

  it "replaces the answer with one current attachment" do
    submission = described_class.create!(attributes)
    [ "material.pdf", "material.txt" ].each do |filename|
      File.open(Rails.root.join("spec/fixtures/files", filename), "rb") do |file|
        submission.answer_file.attach(io: file, filename: filename)
      end
    end

    expect(submission.reload.answer_file.filename.to_s).to eq("material.txt")
    expect(ActiveStorage::Attachment.where(record: submission, name: "answer_file").count).to eq(1)
  end

  it "enforces assignment and student uniqueness in the database" do
    described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(attributes).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  [ :assignment_id, :student_id, :status, :submitted_at ].each do |column|
    it "rejects NULL #{column} in the database" do
      submission = described_class.new(attributes)
      submission[column] = nil

      expect do
        described_class.transaction(requires_new: true) do
          submission.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  { assignment_id: Assignment, student_id: Student }.each do |column, model|
    it "rejects a nonexistent #{column} in the database" do
      submission = described_class.new(attributes)
      submission[column] = model.maximum(:id) + 1

      expect do
        described_class.transaction(requires_new: true) do
          submission.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
