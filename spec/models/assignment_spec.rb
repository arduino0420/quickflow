require "rails_helper"

RSpec.describe Assignment, type: :model do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:attributes) { { teacher: teacher, title: "Quiz", point_per_question: 5 } }

  it "persists its teacher without material, classrooms or a publication date" do
    assignment = described_class.create!(attributes).reload

    expect(assignment.teacher).to eq(teacher)
    expect(assignment.material_file).not_to be_attached
    expect(assignment.classrooms).to be_empty
    expect(assignment.published_at).to be_nil
  end

  it "returns its questions" do
    assignment = described_class.create!(attributes)
    question = Question.create!(assignment: assignment, question_label: "1", position: 1,
      question_text: "1 + 1", correct_answer: "2", answer_generation_model: "test-model",
      answer_generation_prompt_version: "v1", answer_generated_at: Time.current)

    expect(assignment.questions).to contain_exactly(question)
  end

  it "requires a teacher" do
    assignment = described_class.new(attributes.merge(teacher: nil))

    expect(assignment).not_to be_valid
    expect(assignment.errors[:teacher]).to be_present
  end

  [ nil, "", " " ].each do |title|
    it "rejects title #{title.inspect}" do
      assignment = described_class.new(attributes.merge(title: title))

      expect(assignment).not_to be_valid
      expect(assignment.errors[:title]).to be_present
    end
  end

  [ 1, 100 ].each do |points|
    it "accepts #{points} points per question" do
      expect(described_class.new(attributes.merge(point_per_question: points))).to be_valid
    end
  end

  [ nil, "", 0, -1, 1.5, "abc" ].each do |points|
    it "rejects points per question #{points.inspect}" do
      assignment = described_class.new(attributes.merge(point_per_question: points))

      expect(assignment).not_to be_valid
      expect(assignment.errors[:point_per_question]).to be_present
    end
  end

  it "allows duplicate titles" do
    described_class.create!(attributes)

    expect(described_class.create!(attributes)).to be_persisted
  end

  it "preserves a supplied publication date" do
    date = Time.zone.local(2026, 10, 1, 9)
    assignment = described_class.create!(attributes.merge(published_at: date))

    expect(assignment.reload.published_at).to eq(date)
  end

  it "returns multiple distribution records and classrooms" do
    assignment = described_class.create!(attributes)
    classrooms = [ 1, 2 ].map do |number|
      Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: number)
    end
    distributions = classrooms.map do |classroom|
      AssignmentClassroom.create!(assignment: assignment, classroom: classroom)
    end

    expect(assignment.assignment_classrooms).to contain_exactly(*distributions)
    expect(assignment.classrooms).to contain_exactly(*classrooms)
  end

  { "material.pdf" => "application/pdf", "material.txt" => "text/plain" }.each do |filename, content_type|
    it "stores and retrieves #{filename}" do
      assignment = described_class.create!(attributes)
      path = Rails.root.join("spec/fixtures/files", filename)
      File.open(path, "rb") do |file|
        assignment.material_file.attach(io: file, filename: filename, content_type: content_type)
      end

      assignment.reload
      expect(assignment.material_file).to be_attached
      expect(assignment.material_file.filename.to_s).to eq(filename)
      expect(assignment.material_file.download).to eq(File.binread(path))
    end
  end

  it "replaces the material with a single current attachment" do
    assignment = described_class.create!(attributes)
    [ "material.pdf", "material.txt" ].each do |filename|
      File.open(Rails.root.join("spec/fixtures/files", filename), "rb") do |file|
        assignment.material_file.attach(io: file, filename: filename)
      end
    end

    assignment.reload
    expect(assignment.material_file.filename.to_s).to eq("material.txt")
    expect(ActiveStorage::Attachment.where(record: assignment, name: "material_file").count).to eq(1)
  end

  [ :teacher_id, :title, :point_per_question ].each do |column|
    it "rejects NULL #{column} in the database" do
      assignment = described_class.new(attributes)
      assignment[column] = nil

      expect do
        described_class.transaction(requires_new: true) do
          assignment.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  it "rejects a nonexistent teacher in the database" do
    assignment = described_class.new(attributes)
    assignment.teacher_id = Teacher.maximum(:id) + 1

    expect do
      described_class.transaction(requires_new: true) do
        assignment.save!(validate: false)
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
