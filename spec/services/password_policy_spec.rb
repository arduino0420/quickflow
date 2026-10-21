require "rails_helper"

RSpec.describe PasswordPolicy do
  it "accepts a 15-digit student secret but does not claim it was randomly generated" do
    expect(described_class.message_for("739162840517294", role: :student)).to be_nil
  end

  [ "123456789012345", "000000000000000", "121212121212121", "12345", "student-password" ].each do |value|
    it "rejects a weak or malformed student secret" do
      expect(described_class.message_for(value, role: :student)).to be_present
    end
  end

  it "accepts a long staff passphrase and rejects common or excessive values" do
    expect(described_class.message_for("Long River 8 Beacon 42", role: :teacher)).to be_nil
    expect(described_class.message_for("short", role: :teacher)).to be_present
    expect(described_class.message_for("password123456789", role: :teacher)).to be_present
    expect(described_class.message_for("a" * 15, role: :admin)).to be_present
    expect(described_class.message_for("あ" * 25, role: :admin)).to include("72バイト")
    expect(described_class.message_for("あいうえおかきくけこさしすせそたちつてと", role: :admin)).to be_nil
  end

  it "does not apply the new rule to an unchanged legacy password" do
    school = School.create!(school_code: "POLICY")
    teacher = Teacher.create!(school: school, user_id: "legacy", password: "old-password")
    expect(teacher.update(user_id: teacher.user_id)).to be(true)
    expect(teacher.reload.authenticate("old-password")).to eq(teacher)
    expect(teacher.update(password: "short")).to be(false)
    expect(teacher.reload.authenticate("old-password")).to eq(teacher)
  end

  it "applies the new policy to an existing admin password change" do
    school = School.create!(school_code: "ADMINPOL")
    admin = Admin.create!(school: school, user_id: "legacy-admin", password: "old-password")
    expect(admin.update(password: "short")).to be(false)
    expect(admin.reload.update(password: "Long River 8 Beacon 42")).to be(true)
    expect(admin.reload.authenticate("Long River 8 Beacon 42")).to eq(admin)
  end
end
