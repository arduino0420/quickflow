require "rails_helper"

RSpec.describe Student, type: :model do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:attributes) { { classroom: classroom, attendance_number: 1, password: "password123" } }

  it "persists its classroom" do
    student = described_class.create!(attributes)

    expect(student.reload.classroom).to eq(classroom)
  end

  it "requires a classroom" do
    student = described_class.new(attributes.merge(classroom: nil))

    expect(student).not_to be_valid
    expect(student.errors[:classroom]).to be_present
  end

  [ 1, 40 ].each do |number|
    it "accepts attendance number #{number}" do
      expect(described_class.new(attributes.merge(attendance_number: number))).to be_valid
    end
  end

  [ nil, "", 0, 41, -1, 1.5, "abc" ].each do |number|
    it "rejects attendance number #{number.inspect}" do
      student = described_class.new(attributes.merge(attendance_number: number))

      expect(student).not_to be_valid
      expect(student.errors[:attendance_number]).to be_present
    end
  end

  it "rejects a duplicate attendance number in the same classroom" do
    described_class.create!(attributes)
    duplicate = described_class.new(attributes)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:attendance_number]).to be_present
  end

  it "allows the same attendance number in another classroom" do
    described_class.create!(attributes)
    other_classroom = Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 2)

    expect(described_class.new(attributes.merge(classroom: other_classroom))).to be_valid
  end

  it "requires a password when creating a student" do
    student = described_class.new(attributes.except(:password))

    expect(student).not_to be_valid
    expect(student.errors[:password]).to be_present
  end

  it "stores a password hash and authenticates the password" do
    student = described_class.create!(attributes).reload

    expect(student.password_digest).to be_present
    expect(student.password_digest).not_to eq("password123")
    expect(student.authenticate("password123")).to eq(student)
    expect(student.authenticate("wrong-password")).to be(false)
  end

  it "allows an update without supplying the password again" do
    student = described_class.create!(attributes).reload

    expect(student.update(attendance_number: 2)).to be(true)
    expect(student.authenticate("password123")).to eq(student)
  end

  it "rejects a mismatched password confirmation" do
    student = described_class.new(attributes.merge(password_confirmation: "different"))

    expect(student).not_to be_valid
    expect(student.errors[:password_confirmation]).to be_present
  end

  it "rejects passwords longer than 72 bytes" do
    student = described_class.new(attributes.merge(password: "a" * 73))

    expect(student).not_to be_valid
    expect(student.errors[:password]).to be_present
  end

  it "does not enable password reset tokens" do
    expect(described_class.new).not_to respond_to(:password_reset_token)
  end

  it "enforces classroom and attendance number uniqueness in the database" do
    described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(attributes).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  [ :classroom_id, :attendance_number, :password_digest ].each do |column|
    it "rejects NULL #{column} in the database" do
      student = described_class.new(attributes)
      student[column] = nil

      expect do
        described_class.transaction(requires_new: true) do
          student.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  it "rejects a nonexistent classroom in the database" do
    student = described_class.new(attributes)
    student.classroom_id = Classroom.maximum(:id) + 1

    expect do
      described_class.transaction(requires_new: true) do
        student.save!(validate: false)
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
