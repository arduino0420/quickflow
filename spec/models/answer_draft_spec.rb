require "rails_helper"

RSpec.describe AnswerDraft, type: :model do
  let(:school) { School.create!(school_code: "DRAFT") }
  let(:teacher) { Teacher.create!(school: school, user_id: "draft-model", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  let(:assignment) { Assignment.create!(teacher: teacher, title: "下書き", point_per_question: 5) }
  let(:stroke) { { "id" => 1, "tool" => "pen", "width" => 1.2, "color" => "#000000", "points" => [ [ 20, 30 ] ] } }
  let(:draft) { described_class.new(student: student, assignment: assignment, material_fingerprint: "a" * 64, page_data: [ { "page_number" => 1, "operations" => [ stroke ] } ]) }

  it "filters handwritten payloads from model inspection and SQL bind logging" do
    expect(AnswerDraft.filter_attributes).to include(:page_data)
    expect(draft.inspect).not_to include("points")
    expect(ActiveRecord::Base.inspection_filter.filter_param("page_data", draft.page_data)).to eq("[FILTERED]")
  end

  it "persists versioned ordered operations and enforces student/assignment uniqueness in the DB" do
    draft.save!
    expect(draft.lock_version).to eq(0)
    copy = draft.dup
    expect(copy).not_to be_valid
    expect { copy.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "detects stale saves with optimistic locking" do
    draft.save!
    stale = described_class.find(draft.id)
    draft.update!(page_data: [ { "page_number" => 1, "operations" => [] } ])
    expect { stale.update!(format_version: 1, updated_at: Time.current) }.to raise_error(ActiveRecord::StaleObjectError)
  end

  [ 4, 8, 12 ].each do |width|
    it "preserves eraser width #{width} and operation order on multiple pages" do
      draft.page_data << { "page_number" => 2, "operations" => [ stroke.merge("tool" => "eraser", "width" => width) ] }
      draft.save!
      expect(draft.reload.page_data.last["operations"].first["width"]).to eq(width)
    end
  end

  [ nil, {}, [], [ { "page_number" => 2, "operations" => [] } ] ].each do |data|
    it "rejects malformed page data #{data.inspect}" do
      draft.page_data = data
      expect(draft).not_to be_valid
    end
  end

  [ "bad", 1_000_001, Float::INFINITY ].each do |coordinate|
    it "rejects invalid coordinates #{coordinate}" do
      draft.page_data.first["operations"].first["points"] = [ [ coordinate, 0 ] ]
      expect(draft).not_to be_valid
    end
  end

  it "rejects duplicate IDs, unknown tools, invalid widths and format versions" do
    draft.page_data.first["operations"] << stroke.deep_dup
    expect(draft).not_to be_valid
    draft.page_data.first["operations"] = [ stroke.merge("tool" => "whiteout") ]
    expect(draft).not_to be_valid
    draft.page_data.first["operations"] = [ stroke.merge("width" => 100) ]
    expect(draft).not_to be_valid
    draft.format_version = 2
    expect(draft).not_to be_valid
  end

  it "bounds point counts and payload bytes" do
    draft.page_data.first["operations"].first["points"] = Array.new(described_class::MAX_POINTS + 1) { [ 0, 0 ] }
    expect(draft).not_to be_valid
    draft.page_data = [ { "page_number" => 1, "operations" => [ stroke.merge("color" => "x" * described_class::MAX_BYTES) ] } ]
    expect(draft).not_to be_valid
  end
end
