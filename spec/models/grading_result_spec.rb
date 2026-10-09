require "rails_helper"

RSpec.describe GradingResult, type: :model do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  let(:assignment) { Assignment.create!(teacher: teacher, title: "Quiz", point_per_question: 5) }
  let(:submission) { Submission.create!(assignment: assignment, student: student, submitted_at: Time.current) }
  let(:question_attributes) do
    { assignment: assignment, question_label: "1", position: 1, question_text: "1 + 1",
      correct_answer: "2", answer_generation_model: "test-model",
      answer_generation_prompt_version: "v1", answer_generated_at: Time.current }
  end
  let(:question) { Question.create!(question_attributes) }
  let(:attributes) do
    { submission: submission, question: question, ai_judgment: :correct,
      ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.zone.local(2026, 10, 2, 10) }
  end

  [ :correct, :incorrect, :needs_review ].product([ nil, :correct, :incorrect ]).each do |ai, teacher|
    it "derives the final judgment from AI #{ai} and teacher #{teacher.inspect}" do
      result = described_class.new(attributes.merge(ai_judgment: ai, teacher_judgment: teacher))
      expect(result.final_judgment).to eq((teacher || ai).to_s)
      expect(result.ai_judgment).to eq(ai.to_s)
    end
  end

  it "selects only needs_review results with no teacher judgment" do
    pending = described_class.create!(attributes.merge(ai_judgment: :needs_review))
    expect(described_class.pending_review).to include(pending)
    pending.update!(teacher_judgment: :incorrect)
    expect(described_class.pending_review).not_to include(pending)
    pending.update!(teacher_judgment: nil, ai_judgment: :correct)
    expect(described_class.pending_review).not_to include(pending)
    pending.update!(ai_judgment: :incorrect)
    expect(described_class.pending_review).not_to include(pending)
  end

  it "persists its associations and traceability information" do
    result = described_class.create!(attributes).reload

    expect(result.submission).to eq(submission)
    expect(result.question).to eq(question)
    expect(result.ai_model_name).to eq("test-model")
    expect(result.prompt_version).to eq("v1")
    expect(result.graded_at).to eq(attributes[:graded_at])
  end

  [ :submission, :question, :ai_judgment, :ai_model_name, :prompt_version, :graded_at ].each do |attribute|
    it "requires #{attribute}" do
      result = described_class.new(attributes.merge(attribute => nil))

      expect(result).not_to be_valid
      expect(result.errors[attribute]).to be_present
    end
  end

  [ :ai_model_name, :prompt_version ].each do |attribute|
    [ "", " " ].each do |value|
      it "rejects #{attribute} #{value.inspect}" do
        result = described_class.new(attributes.merge(attribute => value))

        expect(result).not_to be_valid
        expect(result.errors[attribute]).to be_present
      end
    end
  end

  it "preserves NULL for all optional fields including both nullable enums" do
    result = described_class.create!(attributes).reload

    [ :student_answer, :reading_confidence, :teacher_judgment, :error_point, :feedback, :review_reason ].each do |attribute|
      expect(result[attribute]).to be_nil
    end
  end

  it "persists optional text fields and a review reason" do
    texts = { student_answer: "3", error_point: "Addition", feedback: "Check the sum", review_reason: "Unclear handwriting" }
    result = described_class.create!(attributes.merge(texts)).reload

    texts.each { |attribute, value| expect(result[attribute]).to eq(value) }
  end

  it "allows needs_review without a review reason" do
    result = described_class.create!(attributes.merge(ai_judgment: :needs_review)).reload

    expect(result).to be_ai_judgment_needs_review
    expect(result.review_reason).to be_nil
  end

  {
    reading_confidence: { low: 0, medium: 1, high: 2 },
    ai_judgment: { incorrect: 0, correct: 1, needs_review: 2 },
    teacher_judgment: { incorrect: 0, correct: 1 }
  }.each do |attribute, mapping|
    it "maps #{attribute} to the specified values" do
      expect(described_class.defined_enums.fetch(attribute.to_s)).to eq(mapping.transform_keys(&:to_s))
    end

    mapping.each do |label, value|
      it "persists #{attribute} #{label} as #{value}" do
        result = described_class.create!(attributes.merge(attribute => label)).reload

        expect(result[attribute]).to eq(label.to_s)
        expect(result.public_send("#{attribute}_before_type_cast")).to eq(value)
        expect(result.public_send("#{attribute}_#{label}?")).to be(true)
      end
    end

    [ "unknown", mapping.values.max + 1 ].each do |value|
      it "rejects undefined #{attribute} #{value.inspect}" do
        expect do
          described_class.new(attributes.merge(attribute => value))
        end.to raise_error(ArgumentError)
      end
    end
  end

  it "keeps AI and teacher judgments independent with prefixed methods" do
    result = described_class.create!(attributes.merge(ai_judgment: :incorrect, teacher_judgment: :correct)).reload

    expect(result).to be_ai_judgment_incorrect
    expect(result).not_to be_ai_judgment_correct
    expect(result).to be_teacher_judgment_correct
    expect(result).not_to be_teacher_judgment_incorrect
  end

  it "rejects duplicate submission and question pairs" do
    described_class.create!(attributes)
    duplicate = described_class.new(attributes)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:question_id]).to be_present
  end

  it "allows another question for the same submission" do
    described_class.create!(attributes)
    other_question = Question.create!(question_attributes.merge(position: 2))

    expect(described_class.create!(attributes.merge(question: other_question))).to be_persisted
  end

  it "allows another submission for the same question" do
    described_class.create!(attributes)
    other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    other_submission = Submission.create!(assignment: assignment, student: other_student, submitted_at: Time.current)

    expect(described_class.create!(attributes.merge(submission: other_submission))).to be_persisted
  end

  it "enforces submission and question uniqueness in the database" do
    described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(attributes).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  [ :submission_id, :question_id, :ai_judgment, :ai_model_name, :prompt_version, :graded_at ].each do |column|
    it "rejects NULL #{column} in the database" do
      result = described_class.new(attributes)
      result[column] = nil

      expect do
        described_class.transaction(requires_new: true) do
          result.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  { submission_id: Submission, question_id: Question }.each do |column, model|
    it "rejects a nonexistent #{column} in the database" do
      result = described_class.new(attributes)
      result[column] = model.maximum(:id) + 1

      expect do
        described_class.transaction(requires_new: true) do
          result.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
