require "rails_helper"

RSpec.describe Admin, type: :model do
  let(:school) { School.create!(school_code: "ADMINA") }
  let(:attributes) { { school: school, user_id: "admin1", password: "synthetic-admin-password" } }

  it "persists an independent admin belonging to an existing school" do
    admin = described_class.create!(attributes).reload

    expect(admin.school).to eq(school)
    expect(admin).not_to be_a(Teacher)
    expect(Teacher.count).to eq(0)
  end

  it "stores only a password hash and authenticates passwords" do
    admin = described_class.create!(attributes).reload

    expect(admin.password_digest).to be_present
    expect(admin.password_digest).not_to eq(attributes[:password])
    expect(admin.authenticate(attributes[:password])).to eq(admin)
    expect(admin.authenticate("wrong-password")).to be(false)
    expect(described_class.column_names).not_to include("password", "password_confirmation")
  end

  [ nil, "", " " ].each do |user_id|
    it "rejects blank admin ID #{user_id.inspect}" do
      admin = described_class.new(attributes.merge(user_id: user_id))

      expect(admin.save).to be(false)
      expect(admin.errors[:user_id]).to be_present
    end
  end

  it "rejects a duplicate admin ID across schools" do
    described_class.create!(attributes)
    other_school = School.create!(school_code: "ADMINB")
    duplicate = described_class.new(attributes.merge(school: other_school))

    expect(duplicate.save).to be(false)
    expect(duplicate.errors[:user_id]).to be_present
  end

  it "keeps the admin and teacher ID namespaces independent" do
    teacher = Teacher.create!(attributes.merge(password: "teacher-password"))
    admin = described_class.create!(attributes)

    expect(admin.authenticate("teacher-password")).to be(false)
    expect(teacher.authenticate(attributes[:password])).to be(false)
  end

  it "requires a school" do
    admin = described_class.new(attributes.merge(school: nil))

    expect(admin.save).to be(false)
    expect(admin.errors[:school]).to be_present
  end

  [ nil, "" ].each do |password|
    it "requires a password on creation: #{password.inspect}" do
      admin = described_class.new(attributes.merge(password: password))

      expect(admin.save).to be(false)
      expect(admin.errors[:password]).to be_present
    end
  end

  it "rejects mismatched password confirmation" do
    admin = described_class.new(attributes.merge(password_confirmation: "different"))

    expect(admin.save).to be(false)
    expect(admin.errors[:password_confirmation]).to be_present
  end

  it "uses the current teacher password policy without adding a minimum length" do
    expect(described_class.create!(attributes.merge(password: "x"))).to be_persisted
  end

  it "allows updates without re-entering the password" do
    admin = described_class.create!(attributes)
    original_digest = admin.password_digest

    expect(admin.update(user_id: "admin2")).to be(true)
    expect(admin.reload.password_digest).to eq(original_digest)
  end

  it "accepts exactly 72 bytes" do
    expect(described_class.create!(attributes.merge(password: "あ" * 24))).to be_persisted
  end

  [ "a" * 73, "あ" * 25 ].each do |password|
    it "rejects passwords exceeding 72 bytes: #{password.bytesize}" do
      admin = described_class.new(attributes.merge(password: password))

      expect(admin.save).to be(false)
      expect(admin.errors[:password]).to be_present
    end
  end

  it "does not enable unused password reset tokens" do
    expect(described_class.new).not_to respond_to(:password_reset_token)
  end

  it "enforces unique IDs in the database when validations are bypassed" do
    described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(attributes).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  [ :school_id, :user_id, :password_digest ].each do |column|
    it "rejects NULL #{column} in the database" do
      admin = described_class.new(attributes)
      admin[column] = nil

      expect do
        described_class.transaction(requires_new: true) do
          admin.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  it "enforces the school foreign key" do
    admin = described_class.new(attributes)
    admin.school_id = School.maximum(:id) + 1

    expect do
      described_class.transaction(requires_new: true) do
        admin.save!(validate: false)
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
