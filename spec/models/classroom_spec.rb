require "rails_helper"

RSpec.describe Classroom, type: :model do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:attributes) { { school: school, teacher: teacher, grade: 1, class_number: 1 } }

  it "returns its assignment classrooms and assignments" do
    classroom = described_class.create!(attributes)
    assignment = Assignment.create!(teacher: teacher, title: "Quiz", point_per_question: 5)
    distribution = AssignmentClassroom.create!(assignment: assignment, classroom: classroom)

    expect(classroom.assignment_classrooms).to contain_exactly(distribution)
    expect(classroom.assignments).to contain_exactly(assignment)
  end

  it "persists its school and teacher" do
    classroom = described_class.create!(attributes).reload

    expect(classroom.school).to eq(school)
    expect(classroom.teacher).to eq(teacher)
  end

  it "returns its students" do
    classroom = described_class.create!(attributes)
    student = Student.create!(classroom: classroom, attendance_number: 1, password: "password123")

    expect(classroom.students).to contain_exactly(student)
  end

  [ :school, :teacher ].each do |association|
    it "requires #{association}" do
      classroom = described_class.new(attributes.merge(association => nil))

      expect(classroom).not_to be_valid
      expect(classroom.errors[association]).to be_present
    end
  end

  [ 1, 2, 3 ].each do |grade|
    it "accepts grade #{grade}" do
      expect(described_class.new(attributes.merge(grade: grade))).to be_valid
    end
  end

  [ nil, "", 0, 4, 1.5, "abc" ].each do |grade|
    it "rejects grade #{grade.inspect}" do
      classroom = described_class.new(attributes.merge(grade: grade))

      expect(classroom).not_to be_valid
      expect(classroom.errors[:grade]).to be_present
    end
  end

  [ 1, 100 ].each do |class_number|
    it "accepts class number #{class_number}" do
      expect(described_class.new(attributes.merge(class_number: class_number))).to be_valid
    end
  end

  [ nil, "", 0, -1, 1.5, "abc" ].each do |class_number|
    it "rejects class number #{class_number.inspect}" do
      classroom = described_class.new(attributes.merge(class_number: class_number))

      expect(classroom).not_to be_valid
      expect(classroom.errors[:class_number]).to be_present
    end
  end

  it "rejects a duplicate school, grade and class number even with another teacher" do
    described_class.create!(attributes)
    other_teacher = Teacher.create!(school: school, user_id: "teacher2", password: "password123")
    duplicate = described_class.new(attributes.merge(teacher: other_teacher))

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:class_number]).to be_present
  end

  it "allows the same grade and class number in another school without matching the teacher school" do
    described_class.create!(attributes)
    other_school = School.create!(school_code: "OTHER1")
    classroom = described_class.create!(attributes.merge(school: other_school))

    expect(classroom.reload.school).to eq(other_school)
    expect(classroom.teacher.school).to eq(school)
  end

  [ { grade: 2 }, { class_number: 2 } ].each do |changes|
    it "allows a different #{changes.keys.first}" do
      described_class.create!(attributes)

      expect(described_class.new(attributes.merge(changes))).to be_valid
    end
  end

  it "enforces the school, grade and class number uniqueness in the database" do
    described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(attributes).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  [ :school_id, :teacher_id, :grade, :class_number ].each do |column|
    it "rejects NULL #{column} in the database" do
      classroom = described_class.new(attributes)
      classroom[column] = nil

      expect do
        described_class.transaction(requires_new: true) do
          classroom.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  { school_id: School, teacher_id: Teacher }.each do |column, model|
    it "rejects a nonexistent #{column} in the database" do
      classroom = described_class.new(attributes)
      classroom[column] = model.maximum(:id) + 1

      expect do
        described_class.transaction(requires_new: true) do
          classroom.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
