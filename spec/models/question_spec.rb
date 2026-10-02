require "rails_helper"

RSpec.describe Question, type: :model do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:assignment) { Assignment.create!(teacher: teacher, title: "Quiz", point_per_question: 5) }
  let(:attributes) do
    { assignment: assignment, question_label: "1", position: 1,
      question_text: "1 + 1", correct_answer: "2", answer_generation_model: "test-model",
      answer_generation_prompt_version: "v1", answer_generated_at: Time.current }
  end

  it "returns its grading results" do
    question = described_class.create!(attributes)
    classroom = Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1)
    student = Student.create!(classroom: classroom, attendance_number: 1, password: "password123")
    submission = Submission.create!(assignment: assignment, student: student, submitted_at: Time.current)
    result = GradingResult.create!(submission: submission, question: question, ai_judgment: :correct,
      ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)

    expect(question.grading_results).to contain_exactly(result)
  end

  it "persists its assignment and allows a NULL grading rule" do
    question = described_class.create!(attributes).reload

    expect(question.assignment).to eq(assignment)
    expect(question.grading_rule).to be_nil
  end

  it "persists an optional grading rule" do
    question = described_class.create!(attributes.merge(grading_rule: "Show your calculation"))

    expect(question.reload.grading_rule).to eq("Show your calculation")
  end

  it "requires an assignment" do
    question = described_class.new(attributes.merge(assignment: nil))

    expect(question).not_to be_valid
    expect(question.errors[:assignment]).to be_present
  end

  [ :question_label, :question_text, :correct_answer, :answer_generation_model,
    :answer_generation_prompt_version, :answer_generated_at, :position ].each do |attribute|
    [ nil, "", " " ].each do |value|
      it "rejects #{attribute} #{value.inspect}" do
        question = described_class.new(attributes.merge(attribute => value))

        expect(question).not_to be_valid
        expect(question.errors[attribute]).to be_present
      end
    end
  end

  [ 1, 100 ].each do |position|
    it "accepts position #{position}" do
      expect(described_class.new(attributes.merge(position: position))).to be_valid
    end
  end

  [ 0, -1, 1.5, "abc" ].each do |position|
    it "rejects position #{position.inspect}" do
      question = described_class.new(attributes.merge(position: position))

      expect(question).not_to be_valid
      expect(question.errors[:position]).to be_present
    end
  end

  it "rejects duplicate positions in the same assignment" do
    described_class.create!(attributes)
    duplicate = described_class.new(attributes)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:position]).to be_present
  end

  it "allows the same position in another assignment" do
    described_class.create!(attributes)
    other_assignment = Assignment.create!(teacher: teacher, title: "Other quiz", point_per_question: 5)

    expect(described_class.create!(attributes.merge(assignment: other_assignment))).to be_persisted
  end

  it "allows another position in the same assignment" do
    described_class.create!(attributes)

    expect(described_class.create!(attributes.merge(position: 2))).to be_persisted
  end

  it "enforces assignment and position uniqueness in the database" do
    described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(attributes).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  [ :assignment_id, :question_label, :position, :question_text, :correct_answer,
    :answer_generation_model, :answer_generation_prompt_version, :answer_generated_at ].each do |column|
    it "rejects NULL #{column} in the database" do
      question = described_class.new(attributes)
      question[column] = nil

      expect do
        described_class.transaction(requires_new: true) do
          question.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  it "rejects a nonexistent assignment in the database" do
    question = described_class.new(attributes)
    question.assignment_id = Assignment.maximum(:id) + 1

    expect do
      described_class.transaction(requires_new: true) do
        question.save!(validate: false)
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
