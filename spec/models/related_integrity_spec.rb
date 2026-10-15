require "rails_helper"

RSpec.describe "Related data integrity", type: :model do
  let(:school) { School.create!(school_code: "INTEGRITYA") }
  let(:other_school) { School.create!(school_code: "INTEGRITYB") }
  let(:teacher) { Teacher.create!(school: school, user_id: "integrity-a", password: "password123") }
  let(:colleague) { Teacher.create!(school: school, user_id: "integrity-a2", password: "password123") }
  let(:foreign_teacher) { Teacher.create!(school: other_school, user_id: "integrity-b", password: "password123") }
  let(:classroom) { Classroom.create!(school: school, teacher: teacher, grade: 1, class_number: 1) }
  let(:other_classroom) { Classroom.create!(school: school, teacher: colleague, grade: 1, class_number: 2) }
  let(:foreign_classroom) { Classroom.create!(school: other_school, teacher: foreign_teacher, grade: 1, class_number: 1) }
  let(:student) { Student.create!(classroom: classroom, attendance_number: 1, password: "password123") }
  let(:assignment) do
    item = Assignment.create!(teacher: teacher, title: "Integrity quiz", point_per_question: 5)
    item.assignment_classrooms.create!(classroom: classroom)
    item
  end
  let(:other_assignment) { Assignment.create!(teacher: colleague, title: "Other quiz", point_per_question: 5) }
  let(:submission) { Submission.create!(assignment: assignment, student: student, submitted_at: Time.current) }

  def reject_save(record, attribute)
    expect(record.save).to be(false)
    expect(record.errors[attribute]).to be_present
  end

  def question_for(owner)
    Question.create!(assignment: owner, question_label: "1", position: 1, question_text: "1 + 1", correct_answer: "2",
      answer_generation_model: "test", answer_generation_prompt_version: "v1", answer_generated_at: Time.current)
  end

  describe "Classroom" do
    it "rejects a teacher from another school" do
      reject_save(Classroom.new(school: school, teacher: foreign_teacher, grade: 1, class_number: 3), :teacher)
    end

    it "allows another teacher in the same school" do
      expect(classroom.update(teacher: colleague)).to be(true)
    end

    [ :school, :teacher ].each do |attribute|
      it "rejects a cross-school #{attribute} change without changing stored associations" do
        original = classroom.attributes
        classroom.public_send("#{attribute}=", attribute == :school ? other_school : foreign_teacher)
        reject_save(classroom, :teacher)
        expect(classroom.reload.attributes).to eq(original)
      end

      it "handles missing #{attribute} without an exception" do
        classroom.public_send("#{attribute}=", nil)
        reject_save(classroom, attribute)
      end
    end
  end

  describe "AssignmentClassroom" do
    it "rejects a distribution to another school" do
      reject_save(AssignmentClassroom.new(assignment: assignment, classroom: foreign_classroom), :classroom)
    end

    it "allows a colleague's classroom in the same school" do
      expect(AssignmentClassroom.create!(assignment: assignment, classroom: other_classroom)).to be_persisted
    end

    it "rejects changing a distribution to another school's classroom" do
      link = assignment.assignment_classrooms.sole
      original = link.attributes
      link.classroom = foreign_classroom
      reject_save(link, :classroom)
      expect(link.reload.attributes).to eq(original)
    end

    [ :assignment, :classroom ].each do |attribute|
      it "handles missing #{attribute} without an exception" do
        link = AssignmentClassroom.new(assignment: assignment, classroom: other_classroom)
        link.public_send("#{attribute}=", nil)
        reject_save(link, attribute)
      end
    end
  end

  describe "Submission" do
    it "allows a student in a distributed classroom owned by a colleague" do
      other_assignment.assignment_classrooms.create!(classroom: classroom)
      expect(Submission.create!(assignment: other_assignment, student: student, submitted_at: Time.current)).to be_persisted
    end

    [ :undistributed_classroom, :foreign_school, :no_distribution, :corrupt_distribution ].each do |kind|
      it "rejects #{kind} without saving a submission" do
        owner = case kind
        when :undistributed_classroom
          Student.create!(classroom: other_classroom, attendance_number: 1, password: "password123")
        when :foreign_school, :corrupt_distribution
          Student.create!(classroom: foreign_classroom, attendance_number: 1, password: "password123")
        else student
        end
        target = kind == :no_distribution ? other_assignment : assignment
        if kind == :corrupt_distribution
          # Historical corruption: bypass only the setup of the invalid distribution.
          AssignmentClassroom.new(assignment: target, classroom: foreign_classroom).save!(validate: false)
        end
        item = Submission.new(assignment: target, student: owner, submitted_at: Time.current)
        expect { reject_save(item, :assignment) }.not_to change(Submission, :count)
      end
    end

    it "rejects changing the assignment to an undistributed quiz" do
      original = submission.attributes
      submission.assignment = other_assignment
      reject_save(submission, :assignment)
      expect(submission.reload.attributes).to eq(original)
    end

    [ :assignment, :student ].each do |attribute|
      it "handles missing #{attribute} without an exception" do
        item = Submission.new(assignment: assignment, student: student, submitted_at: Time.current)
        item.public_send("#{attribute}=", nil)
        reject_save(item, attribute)
      end
    end
  end

  describe "GradingResult" do
    let(:question) { question_for(assignment) }
    let(:result_attributes) do
      { submission: submission, question: question, ai_judgment: :correct, teacher_judgment: :incorrect,
        ai_model_name: "test", prompt_version: "v1", graded_at: Time.current }
    end

    it "allows a question from the submission's assignment" do
      expect(GradingResult.create!(result_attributes)).to be_persisted
    end

    it "rejects another assignment's question" do
      item = GradingResult.new(result_attributes.merge(question: question_for(other_assignment)))
      reject_save(item, :question)
    end

    [ :question, :submission ].each do |attribute|
      it "rejects an inconsistent #{attribute} change and preserves the teacher judgment" do
        item = GradingResult.create!(result_attributes)
        original = item.attributes
        other_assignment.assignment_classrooms.create!(classroom: classroom)
        replacement = attribute == :question ? question_for(other_assignment) :
          Submission.create!(assignment: other_assignment, student: student, submitted_at: Time.current)
        item.public_send("#{attribute}=", replacement)
        reject_save(item, :question)
        expect(item.reload.attributes).to eq(original)
      end

      it "handles missing #{attribute} without an exception" do
        item = GradingResult.new(result_attributes)
        item.public_send("#{attribute}=", nil)
        reject_save(item, attribute)
      end
    end
  end
end
