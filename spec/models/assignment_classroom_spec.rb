require "rails_helper"

RSpec.describe AssignmentClassroom, type: :model do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:assignment) { Assignment.create!(teacher: teacher, title: "Quiz", point_per_question: 5) }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:attributes) { { assignment: assignment, classroom: classroom } }

  it "persists its assignment and classroom" do
    distribution = described_class.create!(attributes).reload

    expect(distribution.assignment).to eq(assignment)
    expect(distribution.classroom).to eq(classroom)
  end

  [ :assignment, :classroom ].each do |association|
    it "requires #{association}" do
      distribution = described_class.new(attributes.merge(association => nil))

      expect(distribution).not_to be_valid
      expect(distribution.errors[association]).to be_present
    end
  end

  it "rejects duplicate assignment and classroom pairs" do
    described_class.create!(attributes)
    duplicate = described_class.new(attributes)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:classroom_id]).to be_present
  end

  it "allows the same assignment in another classroom" do
    described_class.create!(attributes)
    other_classroom = Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 2)

    expect(described_class.create!(attributes.merge(classroom: other_classroom))).to be_persisted
  end

  it "allows another assignment in the same classroom" do
    described_class.create!(attributes)
    other_assignment = Assignment.create!(teacher: teacher, title: "Another quiz", point_per_question: 5)

    expect(described_class.create!(attributes.merge(assignment: other_assignment))).to be_persisted
  end

  it "allows a classroom belonging to another teacher and school" do
    other_school = School.create!(school_code: "OTHER1")
    other_teacher = Teacher.create!(school: other_school, user_id: "teacher2", password: "password123")
    other_classroom = Classroom.create!(school: other_school, teacher: other_teacher, grade: 1, class_number: 1)

    expect(described_class.create!(attributes.merge(classroom: other_classroom))).to be_persisted
  end

  it "enforces assignment and classroom uniqueness in the database" do
    described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(attributes).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  [ :assignment_id, :classroom_id ].each do |column|
    it "rejects NULL #{column} in the database" do
      distribution = described_class.new(attributes)
      distribution[column] = nil

      expect do
        described_class.transaction(requires_new: true) do
          distribution.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  { assignment_id: Assignment, classroom_id: Classroom }.each do |column, model|
    it "rejects a nonexistent #{column} in the database" do
      distribution = described_class.new(attributes)
      distribution[column] = model.maximum(:id) + 1

      expect do
        described_class.transaction(requires_new: true) do
          distribution.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
