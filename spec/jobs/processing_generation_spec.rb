require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "Submission processing generations", type: :job do
  include ActiveJob::TestHelper
  include_context "AI grading records"

  let(:reading) { JSON.generate(problems: [ problem ]) }

  it "defaults existing and new submissions to generation zero" do
    expect(submission.processing_generation).to eq(0)
    expect(Submission.find(submission.id).processing_generation).to eq(0)
  end

  it "ignores an old reading job before it changes a newer reading or enqueues grading" do
    submission.update!(processing_generation: 1, status: :grading, extracted_text: reading)
    expect(AnswerReader).not_to receive(:new)
    expect { AnswerReadingJob.perform_now(submission) }.not_to have_enqueued_job(AnswerGradingJob)
    expect(submission.reload).to be_grading
    expect(submission.extracted_text).to eq(reading)
  end

  it "runs an explicit new reading generation and passes it to grading" do
    submission.update!(processing_generation: 1, extracted_text: nil)
    reader = instance_double(AnswerReader, call: reading)
    allow(AnswerReader).to receive(:new).and_return(reader)
    expect { AnswerReadingJob.perform_now(submission, 1) }.to have_enqueued_job(AnswerGradingJob).with(submission, 1)
    expect(submission.reload.extracted_text).to eq(reading)
  end

  it "does not mark a newer generation failed when an old reading enqueue fails" do
    submission.update!(processing_generation: 1, status: :grading)
    expect(AnswerGradingJob).not_to receive(:perform_later)
    AnswerReadingJob.perform_now(submission, 0)
    expect(submission.reload).to be_grading
  end

  it "ignores old grading jobs before reading saved questions or saving results" do
    submission.update!(processing_generation: 1, status: :grading)
    expect(QuestionGenerator).not_to receive(:new)
    AnswerGradingJob.perform_now(submission)
    expect(submission.reload).to be_grading
    expect(submission.grading_results).to be_empty
  end

  it "does not let an old grading rescue fail a newer generation" do
    submission.update!(status: :grading)
    allow(AnswerGrader).to receive(:reading_problems) do
      submission.update!(processing_generation: 1)
      raise "invalid reading"
    end
    AnswerGradingJob.perform_now(submission, 0)
    expect(submission.reload).to be_grading
  end

  it "grades an explicit new generation once and retains a teacher judgment" do
    question = create_question
    generator = instance_double(QuestionGenerator, saved_questions: [ question ])
    grader = instance_double(AnswerGrader, call: [ {
      question: question, student_answer: "5x", ai_judgment: :correct,
      ai_model_name: "test-model", prompt_version: "v1", graded_at: Time.current
    } ])
    allow(QuestionGenerator).to receive(:new).and_return(generator)
    allow(AnswerGrader).to receive(:new).and_return(grader)
    submission.update!(processing_generation: 1)

    AnswerGradingJob.perform_now(submission, 1)
    saved = submission.grading_results.sole
    saved.update!(teacher_judgment: :incorrect)
    AnswerGradingJob.perform_now(Submission.find(submission.id), 1)
    AnswerGradingJob.perform_now(Submission.find(submission.id), 0)

    expect(submission.reload).to be_completed
    expect(submission.grading_results.count).to eq(1)
    expect(saved.reload).to be_teacher_judgment_incorrect
    expect(grader).to have_received(:call).once
  end

  it "does not grade or change status when results already exist" do
    question = create_question
    submission.grading_results.create!(question: question, ai_judgment: :correct,
      teacher_judgment: :incorrect, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    submission.update!(processing_generation: 1, status: :grading)
    generator = instance_double(QuestionGenerator, saved_questions: [ question ])
    allow(QuestionGenerator).to receive(:new).and_return(generator)
    expect(AnswerGrader).not_to receive(:new)
    AnswerGradingJob.perform_now(submission, 1)
    expect(submission.reload).to be_grading
    expect(submission.grading_results.sole).to be_teacher_judgment_incorrect
  end

  [ :reading, :questions ].each do |stage|
    it "preserves grading status and teacher judgment when #{stage} validation raises before the result guard" do
      question = create_question
      result = submission.grading_results.create!(question: question, ai_judgment: :correct,
        teacher_judgment: :incorrect, ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
      submission.update!(processing_generation: 1, status: :grading)
      if stage == :reading
        allow(AnswerGrader).to receive(:reading_problems).and_raise("invalid reading")
      else
        generator = instance_double(QuestionGenerator, saved_questions: nil)
        allow(QuestionGenerator).to receive(:new).and_return(generator)
        allow(generator).to receive(:saved_questions).and_raise("invalid saved questions")
      end

      AnswerGradingJob.perform_now(submission, 1)

      expect(submission.reload).to be_grading
      expect(submission.grading_results.pluck(:id)).to eq([ result.id ])
      expect(result.reload).to be_teacher_judgment_incorrect
    end
  end

  it "does not let an old question job fail a newer submission" do
    submission.update!(processing_generation: 1, status: :grading)
    request = QuestionGenerationRequest.select_for_distribution!(assignment)
    token = request.claim!
    generator = instance_double(QuestionGenerator, claim_token: token, failure_recorded: true)
    allow(QuestionGenerator).to receive(:new).and_return(generator)
    allow(generator).to receive(:call) do
      request.fail!(token: token)
      raise StandardError, "generation failed"
    end
    QuestionGenerationJob.perform_now(assignment, request.material_blob_id, request_id: request.id)
    expect(request.reload.state).to eq("failed")
    expect(submission.reload).to be_grading
    expect(submission.grading_results).to be_empty
  end

  it "does not let an old question job enqueue grading for a newer submission" do
    submission.update!(processing_generation: 1, status: :grading)
    request = QuestionGenerationRequest.select_for_distribution!(assignment)
    request.update!(state: "succeeded", claim_token: "token")
    generator = instance_double(QuestionGenerator, call: [ create_question ], claim_token: nil)
    allow(QuestionGenerator).to receive(:new).and_return(generator)
    expect { QuestionGenerationJob.perform_now(assignment, request.material_blob_id, request_id: request.id) }.not_to have_enqueued_job(AnswerGradingJob)
    expect(submission.reload).to be_grading
  end

  it "does not let an old question enqueue failure mark a newer submission failed" do
    submission.update!(status: :grading)
    request = QuestionGenerationRequest.select_for_distribution!(assignment)
    request.update!(state: "succeeded", claim_token: "token")
    generator = instance_double(QuestionGenerator, call: [ create_question ], claim_token: nil)
    allow(QuestionGenerator).to receive(:new).and_return(generator)
    allow(AnswerGradingJob).to receive(:perform_later) do
      submission.update!(processing_generation: 1)
      false
    end
    QuestionGenerationJob.perform_now(assignment, request.material_blob_id, request_id: request.id)
    expect(submission.reload).to be_grading
    expect(submission.processing_generation).to eq(1)
  end
end
