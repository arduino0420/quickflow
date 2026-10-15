require "rails_helper"
require_relative "../support/ai_grading_context"
require_relative "../support/xlsx_inspection"

RSpec.describe ClassroomGradeExporter do
  include_context "AI grading records"
  include XlsxInspection

  let(:questions) { [ create_question(position: 1), create_question(position: 2) ] }

  before do
    assignment.assignment_classrooms.create!(classroom: classroom)
  end

  def export_sheet
    xlsx_worksheet(described_class.new.call(assignment, classroom))
  end

  def create_export_submission(number, status: :completed, judgments: [ :correct, :correct ], target: classroom)
    pupil = Student.create!(classroom: target, attendance_number: number, password: "password123")
    item = Submission.create!(assignment: assignment, student: pupil, status: status, submitted_at: Time.current)
    judgments.each_with_index do |judgment, index|
      item.grading_results.create!(question: questions[index], ai_judgment: judgment,
        ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)
    end
    item
  end

  it "writes three columns and exactly 40 numbered data rows even for an empty classroom" do
    sheet = export_sheet
    rows = sheet.xpath("/worksheet/sheetData/row")

    expect(rows.size).to eq(41)
    expect(rows.map { |row| row["r"].to_i }).to eq((1..41).to_a)
    expect(rows.map { |row| row.xpath("./c").size }).to all(eq(3))
    expect(%w[A1 B1 C1].map { |ref| xlsx_value(sheet, ref) }).to eq([ "クラス", "出席番号", "得点" ])
    expect((2..41).map { |row| xlsx_value(sheet, "A#{row}") }).to eq([ "1年1組" ] * 40)
    expect((2..41).map { |row| xlsx_value(sheet, "B#{row}") }).to eq((1..40).map(&:to_s))
    expect((2..41).map { |row| xlsx_cell(sheet, "B#{row}")["t"] }).to all(eq("n"))
    expect((2..41).map { |row| xlsx_value(sheet, "C#{row}") }).to all(be_nil)
    expect(classroom.students).to be_empty
  end

  it "keeps gaps and blank scores while exporting numeric zero and provisional scores in attendance order" do
    create_export_submission(40)
    create_export_submission(7, judgments: [ :correct, :needs_review ])
    create_export_submission(6, judgments: [ :incorrect, :incorrect ])
    create_export_submission(5, status: :failed)
    create_export_submission(4, status: :grading)
    create_export_submission(3, status: :submitted)
    Student.create!(classroom: classroom, attendance_number: 2, password: "password123")

    sheet = export_sheet
    expect((2..41).map { |row| xlsx_value(sheet, "B#{row}") }).to eq((1..40).map(&:to_s))
    expect((2..6).map { |row| xlsx_value(sheet, "C#{row}") }).to all(be_nil)
    expect(xlsx_value(sheet, "C7")).to eq("0")
    expect(xlsx_value(sheet, "C8")).to eq("5")
    expect(xlsx_value(sheet, "C41")).to eq("10")
    expect(%w[C7 C8 C41].map { |ref| xlsx_cell(sheet, ref)["t"] }).to all(eq("n"))
  end

  it "exports numeric zero even when all questions still need review" do
    create_export_submission(1, judgments: [ :needs_review, :needs_review ])
    sheet = export_sheet
    expect(xlsx_value(sheet, "C2")).to eq("0")
    expect(xlsx_cell(sheet, "C2")["t"]).to eq("n")
  end

  [ :no_questions, :missing_result, :foreign_result ].each do |condition|
    it "leaves the score blank when a completed submission has #{condition}" do
      item = create_export_submission(1, judgments: condition == :no_questions ? [] : [ :correct ])
      if condition == :foreign_result
        foreign_assignment = Assignment.create!(teacher: teacher, title: "別の課題", point_per_question: 5)
        foreign_question = create_question(owner: foreign_assignment)
        item.grading_results.build(question: foreign_question, ai_judgment: :correct,
          ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current).save!(validate: false) # Historical cross-assignment result.
      end

      expect(item.score).to be_nil
      expect(xlsx_value(export_sheet, "C2")).to be_nil
    end
  end

  it "uses the latest teacher judgments on each export and preserves grading data" do
    item = create_export_submission(1, judgments: [ :incorrect, :needs_review ])
    exporter = described_class.new
    result = item.grading_results.order(:question_id).first
    expect(xlsx_value(xlsx_worksheet(exporter.call(assignment, classroom)), "C2")).to eq("0")

    item.update_teacher_judgments!(result.id.to_s => "correct")
    attributes = item.grading_results.order(:id).map(&:attributes)
    expect(xlsx_value(xlsx_worksheet(exporter.call(assignment, classroom)), "C2")).to eq("5")
    expect(item.grading_results.order(:id).map(&:attributes)).to eq(attributes)
    expect(result.reload.ai_judgment).to eq("incorrect")

    item.update_teacher_judgments!(result.id.to_s => "")
    expect(xlsx_value(xlsx_worksheet(exporter.call(assignment, classroom)), "C2")).to eq("0")
  end

  it "does not mix another classroom's students or another assignment's submissions into the export" do
    own = create_export_submission(1, judgments: [ :incorrect, :incorrect ])
    other_classroom = Classroom.create!(school: school, teacher: teacher, grade: 2, class_number: 1)
    assignment.assignment_classrooms.create!(classroom: other_classroom)
    create_export_submission(1, target: other_classroom)
    create_export_submission(2, target: other_classroom)
    other_assignment = Assignment.create!(teacher: teacher, title: "別の課題", point_per_question: 100)
    other_assignment.assignment_classrooms.create!(classroom: classroom)
    foreign = Submission.create!(assignment: other_assignment, student: own.student, status: :completed, submitted_at: Time.current)
    foreign.grading_results.create!(question: create_question(owner: other_assignment), ai_judgment: :correct,
      ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current)

    sheet = export_sheet
    expect(xlsx_value(sheet, "C2")).to eq("0")
    expect(xlsx_value(sheet, "C3")).to be_nil
    expect((2..41).map { |row| xlsx_value(sheet, "A#{row}") }).to eq([ "1年1組" ] * 40)
  end
end
