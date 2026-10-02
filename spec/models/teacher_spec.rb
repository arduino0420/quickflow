require "rails_helper"

RSpec.describe Teacher, type: :model do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:attributes) { { school: school, user_id: "teacher1", password: "password123" } }

  it "persists a teacher belonging to its school" do
    teacher = described_class.create!(attributes)

    expect(teacher.reload.school).to eq(school)
  end

  [ nil, "", " " ].each do |user_id|
    it "rejects a blank user ID #{user_id.inspect}" do
      teacher = described_class.new(attributes.merge(user_id: user_id))

      expect(teacher).not_to be_valid
      expect(teacher.errors[:user_id]).to be_present
    end
  end

  it "rejects a duplicate user ID even in a different school" do
    described_class.create!(attributes)
    other_school = School.create!(school_code: "OTHER1")
    duplicate = described_class.new(attributes.merge(school: other_school))

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:user_id]).to be_present
  end

  it "requires a school" do
    teacher = described_class.new(attributes.merge(school: nil))

    expect(teacher).not_to be_valid
    expect(teacher.errors[:school]).to be_present
  end

  it "requires a password when creating a teacher" do
    teacher = described_class.new(attributes.except(:password))

    expect(teacher).not_to be_valid
    expect(teacher.errors[:password]).to be_present
  end

  it "stores a password hash and authenticates the password" do
    teacher = described_class.create!(attributes).reload

    expect(teacher.password_digest).to be_present
    expect(teacher.password_digest).not_to eq("password123")
    expect(teacher.authenticate("password123")).to eq(teacher)
    expect(teacher.authenticate("wrong-password")).to be(false)
  end

  it "allows an update without supplying the password again" do
    teacher = described_class.create!(attributes).reload

    expect(teacher.update(user_id: "teacher2")).to be(true)
    expect(teacher.authenticate("password123")).to eq(teacher)
  end

  it "rejects a mismatched password confirmation" do
    teacher = described_class.new(attributes.merge(password_confirmation: "different"))

    expect(teacher).not_to be_valid
    expect(teacher.errors[:password_confirmation]).to be_present
  end

  it "rejects passwords longer than 72 bytes" do
    teacher = described_class.new(attributes.merge(password: "a" * 73))

    expect(teacher).not_to be_valid
    expect(teacher.errors[:password]).to be_present
  end

  it "does not enable password reset tokens" do
    expect(described_class.new).not_to respond_to(:password_reset_token)
  end

  it "enforces user ID uniqueness in the database" do
    described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(attributes).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  [ :school_id, :user_id, :password_digest ].each do |column|
    it "rejects NULL #{column} in the database" do
      teacher = described_class.new(attributes)
      teacher[column] = nil

      expect do
        described_class.transaction(requires_new: true) do
          teacher.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  it "rejects a nonexistent school in the database" do
    teacher = described_class.new(attributes)
    teacher.school_id = School.maximum(:id) + 1

    expect do
      described_class.transaction(requires_new: true) do
        teacher.save!(validate: false)
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
