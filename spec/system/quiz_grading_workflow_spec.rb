require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"
require "tmpdir"
require_relative "../support/crud_browser"
require_relative "../support/xlsx_inspection"

RSpec.describe "Quiz grading workflow in Chrome", type: :system do
  include CrudBrowser
  include ActiveJob::TestHelper
  include XlsxInspection

  let(:files) { instance_double(OpenAI::Resources::Files) }
  let(:responses) { instance_double(OpenAI::Resources::Responses) }
  let(:client) { instance_double(OpenAI::Client, files: files, responses: responses) }

  def ai_response(data)
    instance_double(OpenAI::Models::Responses::Response, output_text: JSON.generate(data), model: "stub-model",
      status: "completed", output: [], error: nil, incomplete_details: nil)
  end

  before do
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    @school = School.create!(school_code: "CRUDWORKFLOW")
    @teacher = Teacher.create!(school: @school, user_id: "workflow-crud", password: "password123")
    @room = Classroom.create!(school: @school, teachers: [ @teacher ], grade: 1, class_number: 1)
    @student = Student.create!(classroom: @room, attendance_number: 1, password: "password123")
    @unsubmitted = Student.create!(classroom: @room, attendance_number: 2, password: "password123")
    expect(OpenAI::Client).not_to receive(:new)
    # Only the external AI boundary is replaced. Generators/readers/graders/jobs persist normally.
    allow(AiClient).to receive(:build).and_return(client)
    allow(files).to receive(:create).and_return(double(id: "stub-file"))
    allow(responses).to receive(:create) do |request|
      if request[:instructions]&.include?("添付教材")
        expect(@generation_request.reload.state).to eq("running")
        expect(@generation_request.claim_token).to be_present
        ai_response(questions: (1..3).map { |n|
          { question_label: n.to_s, question_text: "3x+2x", correct_answer: "5x", grading_rule: "同類項", requires_work: false }
        })
      elsif request[:instructions].nil?
        ai_response(problems: (1..3).map { |n|
          { question_label: n.to_s, question_text: "3x+2x", student_answer: n == 3 && !@fully_readable ? nil : "6x",
            reading_status: n == 3 && !@fully_readable ? "unclear" : "readable", reading_reason: "固定読み取り根拠" }
        })
      else
        raise "Synthetic grading outage" if @grading_outage

        ai_response(results: JSON.parse(request.fetch(:input)).fetch("problems").map { |problem|
          { question_id: problem.fetch("question_id"), ai_judgment: "incorrect", error_point: "係数",
            feedback: "同類項を確認", review_reason: nil }
        })
      end
    end
    teacher_login(@teacher)
    @assignment = distribute(title: "ブラウザ採点フロー", classrooms: [ @room ])
    @generation_request = @assignment.reload.current_question_generation_request
    expect(@generation_request).to be_persisted
    expect(@generation_request.assignment_id).to eq(@assignment.id)
    expect(@generation_request.material_blob_id).to eq(@assignment.material_file.blob.id)
    expect(@generation_request.state).to eq("pending")
    perform_enqueued_jobs(only: QuestionGenerationJob)
    expect(@generation_request.reload.state).to eq("succeeded")
    expect(@generation_request.finished_at).to be_present
    expect(@generation_request.failure_code).to be_nil
    expect(@assignment.questions.count).to eq(3)
    @questions_before = @assignment.questions.order(:id).map(&:attributes)
  end

  def complete_jobs(submission)
    expect(AnswerReadingJob).to have_been_enqueued.with(submission).once
    perform_enqueued_jobs(only: AnswerReadingJob)
    expect(submission.reload).to be_grading
    expect(submission.extracted_text).to include("固定読み取り根拠")
    expect(AnswerGradingJob).to have_been_enqueued.with(submission, 0, admission: kind_of(String)).once
    perform_enqueued_jobs(only: AnswerGradingJob)
  end

  def download_grade_sheet
    download_directory = Dir.mktmpdir("issue97-export-", Rails.root.join("tmp"))
    page.driver.browser.execute_cdp("Browser.setDownloadBehavior", behavior: "allow", downloadPath: download_directory)
    click_link "Excel出力"
    download = nil
    Timeout.timeout(15) do
      loop do
        download = Dir.glob(File.join(download_directory, "*.xlsx")).first
        break if download
        sleep 0.05 # Bounded wait for the actual browser download, not a fixed delay.
      end
    end
    xlsx_worksheet(File.binread(download))
  end

  it "persists generated questions, handwritten PDF and grading, saves teacher judgments, and downloads Excel through the displayed link" do
    student_login(@student)
    click_link @assignment.title
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    draw_answer
    draft = AnswerDraft.find_by!(student: @student, assignment: @assignment)
    draft_before = draft.attributes
    click_button "提出する"
    expect(page).to have_current_path(student_assignment_path(@assignment), wait: 30)
    submission = Submission.find_by!(student: @student, assignment: @assignment)
    expect(submission).to be_submitted
    expect(submission.score).to be_nil
    expect(submission.answer_file.download).to start_with("%PDF")
    expect(draft.reload.attributes).to eq(draft_before)
    complete_jobs(submission)
    expect(submission.reload).to be_completed
    expect(submission.score).to eq(0)
    expect(submission.grading_results.count).to eq(3)
    results = submission.grading_results.order(:question_id).to_a
    expect(results.map(&:teacher_judgment)).to eq([ nil, nil, nil ])
    expect(results.last.ai_judgment).to eq("needs_review")
    original_ai = results.map { |result| result.attributes.except("teacher_judgment", "updated_at") }
    original_reading = submission.extracted_text
    visit student_assignment_path(@assignment)
    expect(page).to have_css("#student-score", text: "0点（暫定）")
    expect(page).not_to have_css("input[type='file']")
    expect(page).to have_css(".final-judgment", text: "要確認")

    teacher_login(@teacher)
    click_link @assignment.title
    expect(page).to have_css("#grade_student_#{@unsubmitted.id} .grade-status", text: "未提出")
    expect(page).to have_css("#grade_student_#{@unsubmitted.id} .grade-score", text: "", exact_text: true)
    sheet = download_grade_sheet
    expect(%w[A2 B2 C2].map { |ref| xlsx_value(sheet, ref) }).to eq([ "1年1組", "1", "0" ])
    expect(xlsx_cell(sheet, "C2")["t"]).to eq("n")
    expect(xlsx_value(sheet, "B3")).to eq(@unsubmitted.attendance_number.to_s)
    expect(xlsx_cell(sheet, "C3")).to be_present
    expect(xlsx_value(sheet, "C3")).to be_nil
    within("#grade_student_#{@student.id}") { click_link }
    expect(page).to have_css("[data-answer-pdf-url-value='#{answer_assignment_submission_path(@assignment, submission)}']")
    @assignment.questions.order(:position).each do |question|
      within("#question_#{question.id}") do
        expect(page).to have_css("dt", text: "問題文", exact_text: true)
        expect(page).to have_css("dd", text: question.question_text, exact_text: true)
        expect(page).to have_css("dt", text: "正答", exact_text: true)
        expect(page).to have_css("dd", text: question.correct_answer, exact_text: true)
      end
    end
    select "正解", from: "問題1の最終判定"
    select "不正解", from: "問題3の最終判定"
    click_button "保存"
    expect(page).to have_content("判定を保存しました。")
    expect(page).to have_css("#submission-score", text: "5点")
    expect(results.map { |result| result.reload.teacher_judgment }).to eq([ "correct", nil, "incorrect" ])
    expect(results.map { |result| result.attributes.except("teacher_judgment", "updated_at") }).to eq(original_ai)
    expect(@assignment.questions.order(:id).map(&:attributes)).to eq(@questions_before)
    expect(submission.reload.extracted_text).to eq(original_reading)
    expect(draft.reload.attributes).to eq(draft_before)
    click_link "小テスト詳細へ戻る"
    sheet = download_grade_sheet
    expect(%w[A2 B2 C2].map { |ref| xlsx_value(sheet, ref) }).to eq([ "1年1組", "1", "5" ])
    expect(xlsx_value(sheet, "B3")).to eq(@unsubmitted.attendance_number.to_s)
    expect(xlsx_cell(sheet, "C3")).to be_present
    expect(xlsx_value(sheet, "C3")).to be_nil
    student_login(@student)
    click_link @assignment.title
    expect(page).to have_css("#student-score", text: "現在の点数：5点", exact_text: true)
    expect(page).to have_css(".final-judgment", text: "最終判定：正解", count: 1, exact_text: true)
    within("#question_#{results.second.question_id}") do
      expect(page).to have_css("dt", text: "正答", exact_text: true)
      expect(page).to have_css("dd", text: "5x", exact_text: true)
    end
    expect(Submission.where(assignment: @assignment, student: @student).count).to eq(1)
    expect(responses).to have_received(:create).exactly(3).times
  end

  it "creates a legacy file upload once, rejects a stale form's replacement, and exposes recovery only under its existing flag" do
    previous_flag = ENV["QUICKFLOW_GRADING_RECOVERY_ENABLED"]
    student_login(@student)
    visit student_assignment_path(@assignment)
    find("summary", text: "従来のPDFアップロード").click
    attach_file "解答PDF", Rails.root.join("spec/fixtures/files/pdf_preview_single.pdf")
    stale = open_new_window
    within_window(stale) do
      visit student_assignment_path(@assignment)
      find("summary", text: "従来のPDFアップロード").click
      attach_file "解答PDF", Rails.root.join("spec/fixtures/files/material.pdf")
    end
    click_button "提出", exact: true
    expect(page).to have_content("採点結果を準備しています。")
    submission = Submission.find_by!(student: @student, assignment: @assignment)
    original = submission.attributes
    blob = submission.answer_file.blob
    pdf = blob.download
    within_window(stale) do
      click_button "提出", exact: true
      expect(page).not_to have_css("input[type='file']")
    end
    stale.close
    expect(submission.reload.attributes).to eq(original)
    expect(submission.answer_file.blob).to eq(blob)
    expect(blob.download).to eq(pdf)
    expect(Submission.where(student: @student, assignment: @assignment).count).to eq(1)
    @grading_outage = true
    @fully_readable = true
    complete_jobs(submission)
    expect(submission.reload).to be_failed
    expect(submission.grading_results).to be_empty
    ENV["QUICKFLOW_GRADING_RECOVERY_ENABLED"] = "false"
    teacher_login(@teacher)
    visit assignment_submission_path(@assignment, submission)
    expect(page).not_to have_button("採点を再開する")
    ENV["QUICKFLOW_GRADING_RECOVERY_ENABLED"] = "true"
    visit assignment_submission_path(@assignment, submission)
    click_button "採点を再開する"
    expect(page).to have_content("採点を再開しました。")
    expect(submission.reload.processing_generation).to eq(1)
    @grading_outage = false
    perform_enqueued_jobs(only: AnswerGradingJob)
    expect(submission.reload).to be_completed
    expect(submission.score).to eq(0)
    expect(submission.answer_file.blob).to eq(blob)
    expect(@assignment.questions.order(:id).map(&:attributes)).to eq(@questions_before)
  ensure
    ENV["QUICKFLOW_GRADING_RECOVERY_ENABLED"] = previous_flag if defined?(previous_flag)
    stale&.close unless stale&.closed?
  end
end
