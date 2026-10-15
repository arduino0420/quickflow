require "rails_helper"

RSpec.describe Submission, type: :model do
  let(:school) { School.create!(school_code: "ABC123") }
  let(:teacher) { Teacher.create!(school: school, user_id: "teacher1", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  let(:assignment) { Assignment.create!(teacher: teacher, title: "Quiz", point_per_question: 5) }
  let(:attributes) { { assignment: assignment, student: student, submitted_at: Time.zone.local(2026, 10, 2, 9) } }

  before { assignment.assignment_classrooms.create!(classroom: classroom) }

  describe "#score" do
    let(:assignment) { Assignment.create!(teacher: teacher, title: "Quiz", point_per_question: 10) }
    let(:submission) { described_class.create!(attributes.merge(status: :completed)) }
    let(:question_count) { 3 }
    let(:questions) { Array.new(question_count) { |index| create_score_question(position: index + 1) } }

    def create_score_question(position:, owner: assignment)
      Question.create!(assignment: owner, question_label: position.to_s, position: position,
        question_text: "1 + 1", correct_answer: "2", answer_generation_model: "test-model",
        answer_generation_prompt_version: "v1", answer_generated_at: Time.current)
    end

    def create_score_result(question, ai_judgment: :correct, teacher_judgment: nil, owner: submission)
      result = owner.grading_results.build(question: question, ai_judgment: ai_judgment, teacher_judgment: teacher_judgment,
        ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
      # Only cross-assignment fixtures simulate historical corruption for score defenses.
      result.save!(validate: question.assignment_id == owner.assignment_id)
      result
    end

    context "with ten questions" do
      let(:question_count) { 10 }

      it "returns 70 for seven correct answers worth ten points each" do
        questions.each_with_index do |question, index|
          create_score_result(question, ai_judgment: index < 7 ? :correct : :incorrect)
        end

        expect(submission.score).to eq(70)
      end
    end

    it "returns integer zero when all AI judgments are incorrect" do
      questions.each { |question| create_score_result(question, ai_judgment: :incorrect) }

      expect(submission.score).to eq(0)
      expect(submission.score).to be_a(Integer)
    end

    it "counts only correct judgments when incorrect and needs_review results are present" do
      [ :correct, :incorrect, :needs_review ].each_with_index do |judgment, index|
        create_score_result(questions[index], ai_judgment: judgment)
      end

      expect(submission.score).to eq(10)
    end

    it "returns the current score of zero when every result still needs review" do
      questions.each { |question| create_score_result(question, ai_judgment: :needs_review) }

      expect(submission.score).to eq(0)
      expect(submission.grading_results.pending_review.count).to eq(3)
    end

    it "increases the score after the teacher changes incorrect to correct" do
      results = questions.map { |question| create_score_result(question, ai_judgment: :incorrect) }
      expect(submission.score).to eq(0)

      submission.update_teacher_judgments!(results.first.id.to_s => "correct")

      expect(submission.score).to eq(10)
      expect(results.first.reload.ai_judgment).to eq("incorrect")
    end

    it "decreases the score after the teacher changes correct to incorrect" do
      results = questions.map { |question| create_score_result(question) }
      expect(submission.score).to eq(30)

      submission.update_teacher_judgments!(results.first.id.to_s => "incorrect")

      expect(submission.score).to eq(20)
      expect(results.first.reload.ai_judgment).to eq("correct")
    end

    it "adds points when the teacher resolves needs_review as correct" do
      results = questions.map { |question| create_score_result(question, ai_judgment: :needs_review) }
      expect(submission.score).to eq(0)

      submission.update_teacher_judgments!(results.first.id.to_s => "correct")

      expect(submission.score).to eq(10)
    end

    [ :correct, :incorrect, :needs_review ].each do |ai_judgment|
      it "returns to AI #{ai_judgment} scoring when the teacher judgment is cleared" do
        results = questions.map do |question|
          create_score_result(question, ai_judgment: ai_judgment,
            teacher_judgment: ai_judgment == :correct ? :incorrect : :correct)
        end
        initial_score = ai_judgment == :correct ? 0 : 30
        expect(submission.score).to eq(initial_score)

        submission.update_teacher_judgments!(results.to_h { |result| [ result.id.to_s, "" ] })

        expect(submission.score).to eq(ai_judgment == :correct ? 30 : 0)
        expect(results.map { |result| result.reload.teacher_judgment }).to all(be_nil)
      end
    end

    it "reads fresh teacher judgments on repeated calls despite preloaded results" do
      results = questions.map { |question| create_score_result(question) }
      submission.grading_results.load
      expect(submission.score).to eq(30)

      GradingResult.find(results.first.id).update!(teacher_judgment: :incorrect)
      expect(submission.score).to eq(20)

      GradingResult.find(results.first.id).update!(teacher_judgment: nil)
      expect(submission.score).to eq(30)
    end

    it "does not save the calculated score or change persisted grading data" do
      results = questions.map { |question| create_score_result(question) }
      original_submission = submission.attributes
      original_results = results.map(&:attributes)

      expect(submission.score).to eq(30)

      expect(submission.reload.attributes).to eq(original_submission)
      expect(results.map { |result| result.reload.attributes }).to eq(original_results)
    end

    it "returns nil for an unsaved submission even when marked completed" do
      expect(described_class.new(attributes.merge(status: :completed)).score).to be_nil
    end

    [ :submitted, :grading, :failed ].each do |status|
      it "returns nil for #{status} even with a full set of correct results" do
        questions.each { |question| create_score_result(question) }
        submission.update!(status: status)

        expect(submission.score).to be_nil
      end
    end

    it "leaves an unsubmitted student without a submission or a score" do
      expect(student.submissions.find_by(assignment: assignment)&.score).to be_nil
      expect(student.submissions).to be_empty
    end

    it "returns nil when the assignment has no questions" do
      expect(submission.score).to be_nil
    end

    it "returns nil when none of the question results have been saved" do
      questions

      expect(submission.score).to be_nil
    end

    it "returns nil when a question result is missing" do
      questions.first(2).each { |question| create_score_result(question) }

      expect(submission.score).to be_nil
    end

    it "returns nil when a foreign result is mixed into otherwise complete results" do
      questions.each { |question| create_score_result(question) }
      other_assignment = Assignment.create!(teacher: teacher, title: "Other quiz", point_per_question: 10)
      create_score_result(create_score_question(position: 1, owner: other_assignment))

      expect(submission.score).to be_nil
    end

    it "returns nil when a foreign result replaces a missing result despite matching counts" do
      questions.first(2).each { |question| create_score_result(question) }
      other_assignment = Assignment.create!(teacher: teacher, title: "Other quiz", point_per_question: 10)
      create_score_result(create_score_question(position: 1, owner: other_assignment))
      expect(submission.grading_results.count).to eq(questions.size)

      expect(submission.score).to be_nil
    end

    it "returns full marks without counting a question more than once" do
      questions.reverse_each { |question| create_score_result(question, teacher_judgment: :correct) }

      full_marks = assignment.questions.count * assignment.point_per_question
      expect(submission.score).to eq(full_marks)
      expect(submission.score).to be <= full_marks
    end

    it "does not include another student's correct results" do
      questions.each { |question| create_score_result(question, ai_judgment: :incorrect) }
      other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
      other_submission = described_class.create!(attributes.merge(student: other_student, status: :completed))
      questions.each { |question| create_score_result(question, owner: other_submission) }

      expect(submission.score).to eq(0)
      expect(other_submission.score).to eq(30)
    end
  end

  it "returns its grading results" do
    submission = described_class.create!(attributes)
    question = Question.create!(assignment: assignment, question_label: "1", position: 1,
      question_text: "1 + 1", correct_answer: "2", answer_generation_model: "test-model",
      answer_generation_prompt_version: "v1", answer_generated_at: Time.current)
    result = GradingResult.create!(submission: submission, question: question, ai_judgment: :correct,
      ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)

    expect(submission.grading_results).to contain_exactly(result)
  end

  it "rechecks the persisted grading status under the lock before saving teacher judgments" do
    submission = described_class.create!(attributes.merge(status: :completed))
    question = Question.create!(assignment: assignment, question_label: "1", position: 1,
      question_text: "1 + 1", correct_answer: "2", answer_generation_model: "test-model",
      answer_generation_prompt_version: "v1", answer_generated_at: Time.current)
    result = submission.grading_results.create!(question: question, ai_judgment: :correct,
      ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
    described_class.find(submission.id).update!(status: :failed)
    expect(submission).to be_completed

    expect { submission.update_teacher_judgments!(result.id.to_s => "incorrect") }
      .to raise_error(Submission::InvalidTeacherJudgments)
    expect(result.reload.teacher_judgment).to be_nil
  end

  it "persists its associations and submitted date without an answer file" do
    submission = described_class.create!(attributes).reload

    expect(submission.assignment).to eq(assignment)
    expect(submission.student).to eq(student)
    expect(submission.submitted_at).to eq(attributes[:submitted_at])
    expect(submission.answer_file).not_to be_attached
  end

  [ :assignment, :student, :submitted_at, :status ].each do |attribute|
    it "requires #{attribute}" do
      submission = described_class.new(attributes.merge(attribute => nil))

      expect(submission).not_to be_valid
      expect(submission.errors[attribute]).to be_present
    end
  end

  it "defaults to submitted and stores zero" do
    submission = described_class.new(attributes)

    expect(submission).to be_submitted
    submission.save!
    expect(submission.reload).to be_submitted
    expect(submission.status_before_type_cast).to eq(0)
    expect(described_class.columns_hash.fetch("status").default).to eq("0")
  end

  it "maps the four enum states" do
    expect(described_class.statuses).to eq("submitted" => 0, "grading" => 1, "completed" => 2, "failed" => 3)
  end

  { submitted: 0, grading: 1, completed: 2, failed: 3 }.each do |status, value|
    it "persists #{status} as #{value}" do
      submission = described_class.create!(attributes.merge(status: status)).reload

      expect(submission.status).to eq(status.to_s)
      expect(submission.status_before_type_cast).to eq(value)
    end
  end

  [ "unknown", 4 ].each do |status|
    it "rejects undefined status #{status.inspect}" do
      expect do
        described_class.new(attributes.merge(status: status))
      end.to raise_error(ArgumentError)
    end
  end

  it "rejects duplicate assignment and student pairs" do
    described_class.create!(attributes)
    duplicate = described_class.new(attributes)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:student_id]).to be_present
  end

  it "allows another student for the same assignment" do
    described_class.create!(attributes)
    other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")

    expect(described_class.create!(attributes.merge(student: other_student))).to be_persisted
  end

  it "allows another assignment for the same student" do
    described_class.create!(attributes)
    other_assignment = Assignment.create!(teacher: teacher, title: "Another quiz", point_per_question: 5)
    other_assignment.assignment_classrooms.create!(classroom: classroom)

    expect(described_class.create!(attributes.merge(assignment: other_assignment))).to be_persisted
  end

  { "material.pdf" => "application/pdf", "material.txt" => "text/plain" }.each do |filename, content_type|
    it "stores and retrieves #{filename} as the answer" do
      submission = described_class.create!(attributes)
      path = Rails.root.join("spec/fixtures/files", filename)
      File.open(path, "rb") do |file|
        submission.answer_file.attach(io: file, filename: filename, content_type: content_type)
      end

      submission.reload
      expect(submission.answer_file).to be_attached
      expect(submission.answer_file.filename.to_s).to eq(filename)
      expect(submission.answer_file.download).to eq(File.binread(path))
    end
  end

  it "replaces the answer with one current attachment" do
    submission = described_class.create!(attributes)
    [ "material.pdf", "material.txt" ].each do |filename|
      File.open(Rails.root.join("spec/fixtures/files", filename), "rb") do |file|
        submission.answer_file.attach(io: file, filename: filename)
      end
    end

    expect(submission.reload.answer_file.filename.to_s).to eq("material.txt")
    expect(ActiveStorage::Attachment.where(record: submission, name: "answer_file").count).to eq(1)
  end

  it "enforces assignment and student uniqueness in the database" do
    described_class.create!(attributes)

    expect do
      described_class.transaction(requires_new: true) do
        described_class.new(attributes).save!(validate: false)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  [ :assignment_id, :student_id, :status, :submitted_at ].each do |column|
    it "rejects NULL #{column} in the database" do
      submission = described_class.new(attributes)
      submission[column] = nil

      expect do
        described_class.transaction(requires_new: true) do
          submission.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::NotNullViolation)
    end
  end

  { assignment_id: Assignment, student_id: Student }.each do |column, model|
    it "rejects a nonexistent #{column} in the database" do
      submission = described_class.new(attributes)
      submission[column] = model.maximum(:id) + 1

      expect do
        described_class.transaction(requires_new: true) do
          submission.save!(validate: false)
        end
      end.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
