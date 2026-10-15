require "rails_helper"
require_relative "../../support/ai_grading_context"

RSpec.describe Recovery::SubmissionInspector do
  include_context "AI grading records"

  subject(:report) { described_class.new.call(submission.reload) }

  before do
    submission.answer_file.attach(io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      filename: "private-answer.pdf", content_type: "application/pdf")
    submission.update!(status: :failed)
  end

  def create_result(question, **attributes)
    submission.grading_results.create!({ question: question, ai_judgment: :correct,
      ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current }.merge(attributes))
  end

  it "identifies grading as a possible restart stage using valid saved data" do
    create_question
    expect(report).to include(status: "failed", reading: "valid", questions: "valid",
      classification: "採点再開の検討対象", result_count: 0, reasons: [])
    expect(report[:answer_pdf]).to eq(attachment_record: true, blob_record: true)
    expect(report[:unchecked]).to include("PDF実体の存在・内容", "失敗キャッシュ", "待機中・実行中Job")
  end

  it "identifies reading as a possible restart stage when no reading is saved" do
    create_question
    submission.update!(extracted_text: nil)
    expect(report).to include(reading: "missing", classification: "読み取り再開の検討対象")
  end

  it "requires question generation investigation when questions are missing" do
    expect(report).to include(questions: "missing", classification: "追加確認が必要")
    expect(report[:reasons].join).to include("正答生成の確認が先")
  end

  [ "private-invalid-json", '{"problems":[]}', '{"problems":[{"reading_status":"unknown"}]}' ].each do |text|
    it "reports invalid saved readings without exposing their content: #{text.length} bytes" do
      create_question
      submission.update!(extracted_text: text)
      expect(report).to include(reading: "invalid", classification: "追加確認が必要")
      expect(report[:reasons].join).to include("読み取り結果の形式が不正")
      expect(report.to_json).not_to include(text)
    end
  end

  it "reports an invalid saved grading rule" do
    create_question.update!(grading_rule: "private-invalid-rule")
    expect(report).to include(questions: "invalid", classification: "追加確認が必要")
    expect(report.to_json).not_to include("private-invalid-rule")
  end

  it "detects a question generated from a different material blob" do
    create_question.update!(grading_rule: JSON.generate(criteria: "private", requires_work: false, material_blob_id: -1))
    expect(report[:questions]).to eq("invalid")
  end

  it "reports missing answer attachment metadata" do
    create_question
    submission.answer_file.detach
    expect(report[:answer_pdf]).to eq(attachment_record: false, blob_record: false)
    expect(report[:classification]).to eq("追加確認が必要")
  end

  it "reports missing material attachment metadata even when saved questions exist" do
    create_question
    assignment.material_file.detach
    expect(report[:material_pdf]).to eq(attachment_record: false, blob_record: false)
    expect(report[:reasons].join).to include("教材PDF")
  end

  it "does not consider a complete set of results on a failed submission safe to restore" do
    create_result(create_question, teacher_judgment: :incorrect)
    expect(report).to include(result_question_ids_match: true, teacher_judgment_present: true,
      classification: "既存結果の確認が必要")
    expect(report[:reasons].join).to include("状態変更の安全性は未確認")
    expect(submission.reload).to be_failed
  end

  it "detects partial results" do
    create_result(create_question)
    create_question(position: 2, label: "1(2)")
    expect(report).to include(question_count: 2, result_count: 1, result_question_ids_match: false,
      classification: "既存結果の確認が必要")
  end

  it "detects results belonging to another assignment even when counts match" do
    create_question
    other = Assignment.create!(teacher: teacher, title: "private-other", point_per_question: 5)
    create_result(create_question(owner: other))
    expect(report).to include(question_count: 1, result_count: 1, result_question_ids_match: false)
    expect(report[:reasons].join).to include("問題IDと一致しません")
  end

  it "detects invalid stored judgments without modifying them" do
    result = create_result(create_question)
    result.update_columns(ai_judgment: 99, teacher_judgment: 99)
    expect(report[:reasons].join).to include("必須情報・判定に不整合")
    expect(result.reload.ai_judgment_before_type_cast).to eq(99)
  end

  it "detects missing explanation required for an incorrect result" do
    create_result(create_question, ai_judgment: :incorrect)
    expect(report[:reasons].join).to include("必須情報・判定に不整合")
  end

  it "excludes completed submissions without claiming their results are valid" do
    create_question
    submission.update!(status: :completed)
    expect(report[:classification]).to eq("完了済み（復旧対象外）")
    expect(report[:reasons].join).to include("問題IDが一致しません")
  end

  it "does not write SQL, change data, enqueue jobs, access cache or PDF bytes, or construct AI clients" do
    result = create_result(create_question, teacher_judgment: :incorrect, student_answer: "PRIVATE-STUDENT-ANSWER")
    models = [ Submission, Assignment, Question, GradingResult, ActiveStorage::Attachment, ActiveStorage::Blob ]
    before_data = models.map { |model| model.order(:id).map(&:attributes) }
    expect(AiClient).not_to receive(:build)
    expect(OpenAI::Client).not_to receive(:new)
    expect(AnswerReadingJob).not_to receive(:perform_later)
    expect(AnswerGradingJob).not_to receive(:perform_later)
    expect(QuestionGenerationJob).not_to receive(:perform_later)
    expect(Rails.cache).not_to receive(:read)
    expect(Rails.cache).not_to receive(:write)
    expect(Rails.cache).not_to receive(:delete)
    expect(ActiveStorage::Blob.service).not_to receive(:download)
    expect(ActiveStorage::Blob.service).not_to receive(:open)
    expect(ActiveStorage::Blob.service).not_to receive(:exist?)
    sql = []
    observer = ->(event) { sql << event.payload[:sql] }
    output = ActiveSupport::Notifications.subscribed(observer, "sql.active_record") do
      described_class.new.call(Submission.find(submission.id)).to_json
    end
    expect(sql).not_to be_empty
    expect(sql.grep(/\b(INSERT|UPDATE|DELETE|MERGE|CREATE|ALTER|DROP|TRUNCATE|nextval|pg_advisory_lock)\b/i)).to be_empty
    expect(models.map { |model| model.order(:id).map(&:attributes) }).to eq(before_data)
    expect(result.reload).to be_teacher_judgment_incorrect
    [ "PRIVATE-STUDENT-ANSWER", problem[:question_text], "5x", teacher.user_id,
      assignment.title, "private-answer.pdf", submission.answer_file.blob.key ].each do |private_value|
      expect(output).not_to include(private_value)
    end
  end
end
