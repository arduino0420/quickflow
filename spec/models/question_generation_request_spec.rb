require "rails_helper"

RSpec.describe QuestionGenerationRequest, type: :model do
  let(:school) { School.create!(school_code: "LEDGERMODEL") }
  let(:teacher) { Teacher.create!(school: school, user_id: "ledger-model", password: "password123") }
  let(:assignment) { Assignment.create!(teacher: teacher, title: "Ledger model", point_per_question: 5) }
  let(:attributes) { { assignment: assignment, material_blob_id: 123, model: "test-model", prompt_version: "test-v1", state: "pending" } }

  it "accepts each declared state" do
    described_class::STATES.each do |state|
      expect(described_class.new(**attributes, state: state)).to be_valid
    end
  end

  it "requires its owning assignment" do
    request = described_class.new(**attributes, assignment: nil)
    expect(request).not_to be_valid
    expect(request.errors[:assignment]).not_to be_empty
  end

  %i[material_blob_id model prompt_version].each do |attribute|
    it "requires #{attribute}" do
      [ nil, "" ].each do |value|
        request = described_class.new(attributes.merge(attribute => value))
        expect(request).not_to be_valid
        expect(request.errors.of_kind?(attribute, :blank)).to be(true)
      end
    end
  end

  it "rejects a state outside the declared states" do
    [ nil, "", "unknown" ].each do |state|
      request = described_class.new(**attributes, state: state)
      expect(request).not_to be_valid
      expect(request.errors.of_kind?(:state, :inclusion)).to be(true)
    end
  end

  it "accepts declared failure codes and nil while rejecting unknown codes" do
    [ nil, *described_class::FAILURE_CODES ].each do |code|
      expect(described_class.new(**attributes, failure_code: code)).to be_valid
    end
    [ "", "unknown" ].each do |code|
      request = described_class.new(**attributes, failure_code: code)
      expect(request).not_to be_valid
      expect(request.errors.of_kind?(:failure_code, :inclusion)).to be(true)
    end
  end

  it "enforces material uniqueness only within the complete declared input scope" do
    described_class.create!(attributes)
    duplicate = described_class.new(attributes)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors.of_kind?(:material_blob_id, :taken)).to be(true)

    other = Assignment.create!(teacher: teacher, title: "Other ledger", point_per_question: 5)
    [ { assignment: other }, { material_blob_id: 124 }, { model: "other-model" }, { prompt_version: "test-v2" } ].each do |change|
      expect(described_class.new(attributes.merge(change))).to be_valid
    end
  end
end
