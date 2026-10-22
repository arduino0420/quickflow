require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe "Durable question generation lifecycle" do
  include_context "AI grading records"
  include ActiveJob::TestHelper

  let(:payload) { { questions: [ { question_label: "1", question_text: "3x+2x", correct_answer: "5x", grading_rule: "combine", requires_work: false } ] } }
  let(:generator) { QuestionGenerator.new(client: client) }

  before do
    allow(files).to receive(:create).and_return(double(id: "file-test"))
    allow(responses).to receive(:create).and_return(ai_response(payload))
  end

  def select_request(model: "model-A")
    QuestionGenerationRequest.select_for_distribution!(assignment, model: model)
  end

  it "persists failure across cache replacement, a fresh instance and environment model changes" do
    request = select_request
    allow(responses).to receive(:create).and_raise("PRIVATE")
    expect { generator.call(assignment) }.to raise_error("PRIVATE")
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::NullStore.new
    allow(AiClient).to receive(:model).and_return("different-model")
    expect(QuestionGenerator.new.failed?(Assignment.find(assignment.id))).to be(true)
    expect(request.reload.attributes.slice("state", "failure_code")).to eq("state" => "failed", "failure_code" => "generation_failed")
    expect(request.started_at).to be_present
    expect(request.finished_at).to be_present
    expect { QuestionGenerator.new(client: client).call(assignment) }.to raise_error(/automatic reattempt/)
    AnswerGradingJob.perform_now(submission)
    expect(submission.reload).to be_failed
    expect(responses).to have_received(:create).once
  ensure
    Rails.cache = original_cache
  end

  it "keeps the failed A row when explicitly selecting B then A" do
    first = select_request
    allow(responses).to receive(:create).and_raise("failed")
    expect { generator.call(assignment) }.to raise_error("failed")
    second = select_request(model: "model-B")
    expect(second.id).not_to eq(first.id)
    selected = select_request
    expect(selected.id).to eq(first.id)
    expect(selected.state).to eq("failed")
    expect { generator.call(assignment) }.to raise_error(/automatic reattempt/)
    expect(QuestionGenerationRequest.count).to eq(2)
    expect(responses).to have_received(:create).once
  end

  it "does not infer intent from legacy jobs, missing cache or read-only access" do
    expect(AiClient).not_to receive(:build)
    expect { generator.call(assignment) }.to raise_error(/history is unknown/)
    expect(generator.saved_questions(assignment)).to eq([])
    QuestionGenerationJob.perform_now(assignment, assignment.material_file.blob.id)
    expect(QuestionGenerationRequest.count).to eq(0)
    expect(responses).not_to have_received(:create)
    expect(Recovery::SubmissionInspector.new.call(submission)[:question_generation]).to eq(state: "legacy_unknown")
  end

  it "reuses valid legacy questions without creating history" do
    question = create_question
    expect(generator.call(assignment)).to eq([ question ])
    expect(QuestionGenerationRequest.count).to eq(0)
    expect(responses).not_to have_received(:create)
  end

  it "leaves an interrupted running worker diagnosable without takeover or replay" do
    request = select_request
    token = request.claim!
    expect(token).to be_present
    request.update!(started_at: 3.days.ago)
    expect(generator.call(assignment)).to be_nil
    QuestionGenerationJob.perform_now(assignment, request.material_blob_id, request_id: request.id)
    info = Recovery::SubmissionInspector.new.call(submission)[:question_generation]
    expect(info[:state]).to eq("running")
    expect(info[:started_at]).to be_present
    expect(request.reload.claim_token).to eq(token)
    expect(responses).not_to have_received(:create)
    expect(AnswerGradingJob).not_to have_been_enqueued
  end

  it "keeps pending intent for an enqueue gap and records a rejected enqueue only while pending" do
    request = select_request
    expect(Recovery::SubmissionInspector.new.call(submission)[:question_generation][:state]).to eq("pending")
    request.enqueue_failed!
    expect(request.reload.state).to eq("failed")
    expect(request.failure_code).to eq("enqueue_failed")
    expect(responses).not_to have_received(:create)
  end

  [ :success, :error ].each do |outcome|
    it "fences delayed #{outcome} after pointer replacement" do
      request = select_request
      allow(responses).to receive(:create) do
        select_request(model: "model-B")
        raise "late error" if outcome == :error

        ai_response(payload)
      end
      expect { generator.call(assignment) }.to raise_error(outcome == :error ? "late error" : /input is stale/)
      # Pointer changes inside the API transaction roll back with its questions.
      expect(assignment.questions.count).to eq(0)
      expect(request.reload.state).to eq("failed")
    end
  end

  it "rejects stale tokens and selected input swaps without failing a different request" do
    first = select_request
    old_token = first.claim!
    first.update!(claim_token: "replacement-token")
    first.fail!(token: old_token)
    expect(first.reload.state).to eq("running")
    second = select_request(model: "model-B")
    first.fail!(token: "replacement-token")
    first.enqueue_failed!
    expect(first.reload.state).to eq("running")
    expect(second.reload.state).to eq("pending")
    QuestionGenerationJob.perform_now(assignment, first.material_blob_id, request_id: first.id)
    expect(responses).not_to have_received(:create)
    expect(second.reload.state).to eq("pending")
  end

  it "fences an old material job and enqueue rejection after a material swap" do
    request = select_request
    assignment.material_file.attach(io: StringIO.new("%PDF-1.4 replacement"), filename: "replacement.pdf", content_type: "application/pdf")
    request.enqueue_failed!
    QuestionGenerationJob.perform_now(assignment, request.material_blob_id, request_id: request.id)
    expect(request.reload.state).to eq("pending")
    expect(submission.reload).to be_submitted
    expect(responses).not_to have_received(:create)
  end

  it "does not accept another assignment's selected request" do
    request = select_request
    other = Assignment.create!(teacher: teacher, title: "Other", point_per_question: 5)
    expect { other.update!(current_question_generation_request: request) }.to raise_error(ActiveRecord::RecordInvalid)
    expect { assignment.question_generation_requests.create!(material_blob_id: request.material_blob_id, model: request.model, prompt_version: request.prompt_version) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
