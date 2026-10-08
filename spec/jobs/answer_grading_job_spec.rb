require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe AnswerGradingJob, type: :job do
  include_context "AI grading records"

  let(:question) { create_question }
  let(:generator) { instance_double(QuestionGenerator) }
  let(:grader) { instance_double(AnswerGrader) }
  let(:result) do
    { question: question, student_answer: "5x", ai_judgment: "correct", ai_model_name: "test-model",
      prompt_version: "v1", graded_at: Time.current }
  end

  before do
    allow(QuestionGenerator).to receive(:new).and_return(generator)
    allow(generator).to receive(:saved_questions).with(assignment).and_return([ question ])
    allow(generator).to receive(:failed?).with(assignment).and_return(false)
    expect(generator).not_to receive(:call)
    allow(AnswerGrader).to receive(:new).and_return(grader)
    allow(grader).to receive(:call).with(submission, [ question ]).and_return([ result ])
  end

  it "saves results, completes the submission, and leaves teacher judgment unset" do
    original_reading = submission.extracted_text
    described_class.perform_now(submission)
    expect(submission.reload).to be_completed
    expect(submission.extracted_text).to eq(original_reading)
    saved = submission.grading_results.sole
    expect(saved).to be_ai_judgment_correct
    expect(saved.teacher_judgment).to be_nil
    expect(saved.ai_model_name).to eq("test-model")
    expect(saved.graded_at).to be_present
  end

  it "completes even if a question needs teacher review" do
    allow(grader).to receive(:call).and_return([ result.merge(ai_judgment: "needs_review", review_reason: "判読困難") ])
    described_class.perform_now(submission)
    expect(submission.reload).to be_completed
    expect(submission.grading_results.sole).to be_ai_judgment_needs_review
  end

  it "does not call generation or grading again after completion or overwrite teacher judgment" do
    described_class.perform_now(submission)
    submission.grading_results.sole.update!(teacher_judgment: :incorrect)
    described_class.perform_now(Submission.find(submission.id))
    expect(generator).to have_received(:saved_questions).once
    expect(grader).to have_received(:call).once
    expect(submission.grading_results.count).to eq(1)
    expect(submission.grading_results.sole).to be_teacher_judgment_incorrect
  end

  it "marks grading failure without discarding readings or shared questions, and does not retry" do
    allow(grader).to receive(:call).and_raise(StandardError, "API error")
    original_reading = submission.extracted_text
    described_class.perform_now(submission)
    described_class.perform_now(Submission.find(submission.id))
    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to eq(original_reading)
    expect(assignment.questions).to contain_exactly(question)
    expect(submission.grading_results).to be_empty
    expect(grader).to have_received(:call).once
  end

  it "waits for prepared questions without generating or grading and preserves readings" do
    allow(generator).to receive(:saved_questions).and_return([])
    original_reading = submission.extracted_text
    described_class.perform_now(submission)
    expect(submission.reload).to be_grading
    expect(submission.extracted_text).to eq(original_reading)
    expect(grader).not_to have_received(:call)
    expect(submission.grading_results).to be_empty
    expect { described_class.perform_now(submission) }.not_to have_enqueued_job(QuestionGenerationJob)
  end

  it "marks known generation failure without calling the grader or generating again" do
    allow(generator).to receive(:saved_questions).and_return([])
    allow(generator).to receive(:failed?).and_return(true)
    described_class.perform_now(submission)
    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to be_present
    expect(grader).not_to have_received(:call)
  end

  it "rejects invalid saved questions without spending on grading" do
    allow(generator).to receive(:saved_questions).and_raise("Invalid saved questions")
    described_class.perform_now(submission)
    expect(submission.reload).to be_failed
    expect(grader).not_to have_received(:call)
  end

  it "logs a grading timeout and preserves readings without retrying the failed submission" do
    error = OpenAI::Errors::APITimeoutError.new(url: URI("https://example.invalid"), message: "Timed out")
    allow(grader).to receive(:call).and_raise(error)
    allow(Rails.logger).to receive(:error)
    original_reading = submission.extracted_text
    described_class.perform_now(submission)
    described_class.perform_now(Submission.find(submission.id))
    expect(submission.reload).to be_failed
    expect(submission.extracted_text).to eq(original_reading)
    expect(submission.grading_results).to be_empty
    expect(grader).to have_received(:call).once
    expect(Rails.logger).to have_received(:error).with(/AnswerGradingJob failed: .*APITimeoutError: Timed out/).once
  end

  it "rejects invalid stored readings before spending on generation" do
    submission.update!(extracted_text: "invalid JSON")
    described_class.perform_now(submission)
    expect(submission.reload).to be_failed
    expect(generator).not_to have_received(:saved_questions)
    expect(grader).not_to have_received(:call)
  end

  it "rolls back all results when a later result cannot be saved" do
    second = create_question(position: 2, label: "1(2)")
    allow(grader).to receive(:call).and_return([ result, result.merge(question: second, ai_model_name: nil) ])
    described_class.perform_now(submission)
    expect(submission.reload).to be_failed
    expect(submission.grading_results).to be_empty
  end

  it "rolls back results if completion cannot be saved" do
    allow(submission).to receive(:update!).with(status: :grading).and_call_original
    allow(submission).to receive(:update!).with(status: :failed).and_call_original
    allow(submission).to receive(:update!).with(status: :completed).and_raise(ActiveRecord::RecordInvalid.new(submission))
    described_class.perform_now(submission)
    expect(submission.reload).to be_failed
    expect(submission.grading_results).to be_empty
  end
end

RSpec.describe "Shared questions after a grading API failure", type: :job do
  include_context "AI grading records"

  it "keeps generated questions and reuses them for another student without a new PDF request" do
    allow(AiClient).to receive(:build).and_return(client)
    allow(files).to receive(:create).and_return(double(id: "file-material"))
    grading_attempts = 0
    allow(responses).to receive(:create) do |request|
      if request[:instructions].include?("添付教材")
        ai_response(questions: [ { question_label: "1(1)", question_text: problem[:question_text], correct_answer: "5x",
          grading_rule: "同類項をまとめる。", requires_work: false } ])
      else
        grading_attempts += 1
        raise "Grading API failed" if grading_attempts == 1

        question_id = JSON.parse(request.fetch(:input)).fetch("problems").sole.fetch("question_id")
        ai_response(results: [ { question_id: question_id, ai_judgment: "correct", error_point: nil, feedback: nil, review_reason: nil } ])
      end
    end

    QuestionGenerationJob.perform_now(assignment, assignment.material_file.blob.id)
    AnswerGradingJob.perform_now(submission)
    expect(submission.reload).to be_failed
    question_id = assignment.questions.sole.id
    other_student = Student.create!(classroom: classroom, attendance_number: 2, password: "password123")
    other_submission = Submission.create!(assignment: assignment, student: other_student, submitted_at: Time.current,
      extracted_text: JSON.generate(problems: [ problem ]))
    AnswerGradingJob.perform_now(other_submission)

    expect(other_submission.reload).to be_completed
    expect(other_submission.grading_results.sole.question_id).to eq(question_id)
    expect(files).to have_received(:create).once
    expect(responses).to have_received(:create).exactly(3).times
    expect(submission.grading_results).to be_empty
  end
end
