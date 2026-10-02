require "rails_helper"

RSpec.describe School, type: :model do
  [ "ABC123", "matsue01", "SCHOOL1" ].each do |code|
    it "accepts the alphanumeric code #{code} without changing its case" do
      school = described_class.create!(school_code: code)

      expect(school.reload.school_code).to eq(code)
    end
  end

  [ nil, "", "学校01", "abc-123", "abc_123", "abc 123", " ", "ＡＢＣ123", "ABC１２３", "ABC123\n" ].each do |code|
    it "rejects the invalid code #{code.inspect}" do
      school = described_class.new(school_code: code)

      expect(school).not_to be_valid
      expect(school.errors[:school_code]).to be_present
    end
  end

  it "rejects a duplicate school code" do
    described_class.create!(school_code: "ABC123")
    duplicate = described_class.new(school_code: "ABC123")

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:school_code]).to be_present
  end

  it "returns its teachers" do
    school = described_class.create!(school_code: "ABC123")
    teacher = Teacher.create!(school: school, user_id: "teacher1", password: "password123")

    expect(school.teachers).to contain_exactly(teacher)
  end

  it "returns its classrooms" do
    school = described_class.create!(school_code: "ABC123")
    teacher = Teacher.create!(school: school, user_id: "teacher1", password: "password123")
    classroom = Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1)

    expect(school.classrooms).to contain_exactly(classroom)
  end

  it "enforces school code uniqueness in the database" do
    described_class.create!(school_code: "ABC123")

    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(school_code: "ABC123").save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "rejects a NULL school code in the database" do
    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(school_code: nil).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::NotNullViolation)
  end
end
