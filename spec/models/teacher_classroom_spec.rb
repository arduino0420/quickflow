require "rails_helper"

RSpec.describe TeacherClassroom, type: :model do
  let(:school) { School.create!(school_code: "LINKA") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:colleague) { Teacher.create!(school: school, user_id: "teacher2", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, grade: 1, class_number: 1) }
  let(:attributes) { { teacher: teacher, classroom: classroom } }

  it "persists its teacher and classroom and exposes both intermediate associations" do
    link = described_class.create!(attributes).reload

    expect(link.teacher).to eq(teacher)
    expect(link.classroom).to eq(classroom)
    expect(teacher.teacher_classrooms).to contain_exactly(link)
    expect(classroom.teacher_classrooms).to contain_exactly(link)
  end

  it "allows multiple teachers in one classroom and exposes both teachers through the classroom" do
    described_class.create!(attributes)
    link = described_class.create!(attributes.merge(teacher: colleague))

    expect(classroom.teacher_classrooms).to include(link)
    expect(classroom.reload.teachers).to contain_exactly(teacher, colleague)
    expect(teacher.reload.classrooms).to contain_exactly(classroom)
    expect(colleague.reload.classrooms).to contain_exactly(classroom)
  end

  it "allows one teacher in multiple classrooms without replacing existing associations" do
    other_classroom = Classroom.create!(school: school, grade: 1, class_number: 2)
    described_class.create!(attributes)
    described_class.create!(attributes.merge(classroom: other_classroom))

    expect(teacher.teacher_classrooms.pluck(:classroom_id)).to match_array([ classroom.id, other_classroom.id ])
    expect(teacher.reload.classrooms).to contain_exactly(classroom, other_classroom)
    expect(other_classroom.reload.teachers).to contain_exactly(teacher)
  end

  it "rejects duplicate teacher and classroom pairs" do
    described_class.create!(attributes)
    duplicate = described_class.new(attributes)

    expect(duplicate.save).to be(false)
    expect(duplicate.errors[:classroom_id]).to be_present
  end

  it "rejects a teacher from another school" do
    foreign_school = School.create!(school_code: "LINKB")
    foreign_teacher = Teacher.create!(school: foreign_school, user_id: "foreign", password: "password123")
    link = described_class.new(attributes.merge(teacher: foreign_teacher))

    expect(link.save).to be(false)
    expect(link.errors[:teacher]).to be_present
  end

  [ :teacher, :classroom ].each do |association|
    it "requires #{association} without raising an exception" do
      link = described_class.new(attributes.merge(association => nil))

      expect(link.save).to be(false)
      expect(link.errors[association]).to be_present
    end

    it "rejects changing #{association} to another school and preserves the saved relationship" do
      link = described_class.create!(attributes)
      original = link.attributes
      foreign_school = School.create!(school_code: "LINKB")
      foreign_teacher = Teacher.create!(school: foreign_school, user_id: "foreign", password: "password123")
      replacement = association == :teacher ? foreign_teacher :
        Classroom.create!(school: foreign_school, grade: 1, class_number: 1)
      link.public_send("#{association}=", replacement)

      expect(link.save).to be(false)
      expect(link.errors[:teacher]).to be_present
      expect(link.reload.attributes).to eq(original)
    end
  end

  it "enforces pair uniqueness in the database even when validations are skipped" do
    described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(attributes).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  { teacher_id: Teacher, classroom_id: Classroom }.each do |column, model|
    it "rejects NULL #{column} in the database" do
      link = described_class.new(attributes)
      link[column] = nil

      expect do
        described_class.transaction(requires_new: true) do
          link.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end

    it "rejects nonexistent #{column} in the database" do
      link = described_class.new(attributes)
      link[column] = model.maximum(:id) + 1

      expect do
        described_class.transaction(requires_new: true) do
          link.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  it "does not create intermediate rows when an existing classroom is created" do
    expect { classroom }.not_to change(described_class, :count)
    expect(classroom.reload.teacher_id).to be_nil
    expect(classroom.teachers).to be_empty
  end

  it "rejects a cross-school relationship added through Teacher.classrooms" do
    foreign_school = School.create!(school_code: "LINKB")
    foreign_classroom = Classroom.create!(school: foreign_school, grade: 1, class_number: 1)
    teacher

    expect { teacher.classrooms << foreign_classroom }.to raise_error(ActiveRecord::RecordInvalid)
    expect(TeacherClassroom.count).to eq(0)
    expect(foreign_classroom.reload.teachers).to be_empty
  end
end
