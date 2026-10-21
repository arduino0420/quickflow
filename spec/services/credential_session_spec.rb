require "rails_helper"

RSpec.describe CredentialSession do
  let(:school) { School.create!(school_code: "CREDENTIAL") }
  let(:teacher) { Teacher.create!(school: school, user_id: "credential-teacher", password: "synthetic-secret") }

  it "binds a proof to the role, account and verified password generation" do
    proof = described_class.issue(teacher)
    admin = Admin.create!(school: school, user_id: "credential-admin", password: "synthetic-secret")
    expect(described_class.valid?(teacher.reload, proof)).to be(true)
    expect(described_class.valid?(admin, proof)).to be(false)
    expect(described_class.valid?(teacher, nil)).to be_falsey
    expect(described_class.valid?(teacher, proof.reverse)).to be(false)
    teacher.touch
    expect(described_class.valid?(teacher.reload, proof)).to be(true)
    teacher.update!(password: "synthetic-secret")
    expect(described_class.valid?(teacher.reload, proof)).to be(false)
  end
end
