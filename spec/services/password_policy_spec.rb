require "rails_helper"

RSpec.describe PasswordPolicy do
  it "accepts eight ASCII digits but does not claim they were randomly generated" do
    expect(described_class.message_for("58392047", role: :student)).to be_nil
  end

  [ "12345678", "87654321", "00000000", "12121212", "1234567", "123456789", "abcd1234", "5839 047", "５８３９２０４７" ].each do |value|
    it "rejects a weak or malformed student secret" do
      expect(described_class.message_for(value, role: :student)).to be_present
    end
  end

  it "accepts ten or more ASCII letters and digits for teachers" do
    expect(described_class.message_for("Matsue2026", role: :teacher)).to be_nil
    expect(described_class.message_for("Teacher8392", role: :teacher)).to be_nil
    expect(described_class.message_for("A" * 71 + "1", role: :teacher)).to be_nil
    [ "abc123", "abcdefghij", "1234567890", "Abcd1234!!", "Abcd 12345", "Ａbcd123456", "Password123", "a" * 72 + "1", "Ab1Ab1Ab1Ab1" ].each do |value|
      expect(described_class.message_for(value, role: :teacher)).to be_present
    end
  end

  it "preserves the administrator policy, including spaces and the 15-character minimum" do
    expect(described_class.message_for("Long River 8 Beacon 42", role: :admin)).to be_nil
    expect(described_class.message_for("Matsue2026", role: :admin)).to include("15文字")
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

  it "keeps a legacy 15-digit student credential valid until it is changed" do
    school = School.create!(school_code: "LEGACYPOL")
    room = Classroom.create!(school: school, grade: 1, class_number: 1)
    student = Student.create!(classroom: room, attendance_number: 1, password: "739162840517294")
    expect(student.reload.authenticate("739162840517294")).to eq(student)
    expect(student.update(attendance_number: 2)).to be(true)
    expect(student.reload.authenticate("739162840517294")).to eq(student)
    expect(student.update(password: "58392047")).to be(true)
    expect(student.reload.authenticate("739162840517294")).to be_falsey
    expect(student.authenticate("58392047")).to eq(student)
  end

  it "applies the new policy to an existing admin password change" do
    school = School.create!(school_code: "ADMINPOL")
    admin = Admin.create!(school: school, user_id: "legacy-admin", password: "old-password")
    expect(admin.update(password: "short")).to be(false)
    expect(admin.reload.update(password: "Long River 8 Beacon 42")).to be(true)
    expect(admin.reload.authenticate("Long River 8 Beacon 42")).to eq(admin)
  end
end
