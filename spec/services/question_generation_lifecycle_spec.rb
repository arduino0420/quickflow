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

  it "uses the persisted model rather than the current generator configuration" do
    select_request(model: "persisted-model")
    QuestionGenerator.new(client: client, model: "changed-environment-model").call(assignment)
    expect(responses).to have_received(:create).with(hash_including(model: "persisted-model")).once
  end

  it "does not execute an unavailable historical prompt version" do
    request = QuestionGenerationRequest.create!(assignment: assignment, material_blob_id: assignment.material_file.blob.id,
      model: "historical-model", prompt_version: "previous-prompt")
    assignment.update!(current_question_generation_request: request)
    expect(generator.call(assignment)).to be_nil
    expect(request.reload.state).to eq("pending")
    expect(responses).not_to have_received(:create)
  end

  [ "changed-model", "", "   " ].each do |current_model|
    it "executes the captured request when the current model becomes #{current_model.inspect}" do
      request = select_request(model: "captured-model")
      original = ENV["OPENAI_QUESTION_GENERATION_MODEL"]
      ENV["OPENAI_QUESTION_GENERATION_MODEL"] = current_model
      allow(AiClient).to receive(:build).and_return(client)
      expect { QuestionGenerationJob.perform_now(assignment, request.material_blob_id, request_id: request.id) }.not_to raise_error
      expect(request.reload.state).to eq("succeeded")
      expect(responses).to have_received(:create).with(hash_including(model: "captured-model")).once
    ensure
      ENV["OPENAI_QUESTION_GENERATION_MODEL"] = original
    end
  end

  it "records captured-request API failure and reads saved history even with a blank current model" do
    request = select_request
    original = ENV["OPENAI_QUESTION_GENERATION_MODEL"]
    ENV["OPENAI_QUESTION_GENERATION_MODEL"] = ""
    allow(AiClient).to receive(:build).and_return(client)
    allow(responses).to receive(:create).and_raise("synthetic API failure")
    expect { QuestionGenerationJob.perform_now(assignment, request.material_blob_id, request_id: request.id) }.not_to raise_error
    expect(request.reload.state).to eq("failed")
    expect(request.failure_code).to eq("generation_failed")
    expect(QuestionGenerator.new.failed?(assignment)).to be(true)
    expect(QuestionGenerator.new.saved_questions(assignment)).to eq([])
    AnswerGradingJob.perform_now(submission)
    expect(submission.reload).to be_failed
    expect(responses).to have_received(:create).once
  ensure
    ENV["OPENAI_QUESTION_GENERATION_MODEL"] = original
  end

  it "reads valid legacy questions with a blank current model without creating durable history" do
    question = create_question
    original = ENV["OPENAI_QUESTION_GENERATION_MODEL"]
    ENV["OPENAI_QUESTION_GENERATION_MODEL"] = ""
    expect(QuestionGenerator.new.saved_questions(assignment)).to eq([ question ])
    expect(QuestionGenerationRequest.count).to eq(0)
    expect(responses).not_to have_received(:create)
  ensure
    ENV["OPENAI_QUESTION_GENERATION_MODEL"] = original
  end

  it "keeps a selected historical prompt failure visible to late submissions without executing that prompt" do
    request = QuestionGenerationRequest.create!(assignment: assignment, material_blob_id: assignment.material_file.blob.id,
      model: "historical-model", prompt_version: "previous-prompt", state: "failed", failure_code: "generation_failed")
    assignment.update!(current_question_generation_request: request)
    expect(QuestionGenerator.new.failed?(assignment)).to be(true)
    AnswerGradingJob.perform_now(submission)
    expect(submission.reload).to be_failed
    expect(responses).not_to have_received(:create)
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

  it "does not let a legacy job infer a current request even when one exists" do
    request = select_request
    QuestionGenerationJob.perform_now(assignment, request.material_blob_id)
    expect(request.reload.state).to eq("pending")
    expect(request.claim_token).to be_nil
    expect(responses).not_to have_received(:create)
  end

  [ nil, 0, false ].each do |blob_id|
    it "does not treat #{blob_id.inspect} as the immutable job input" do
      request = select_request
      QuestionGenerationJob.perform_now(assignment, blob_id, request_id: request.id)
      expect(request.reload.state).to eq("pending")
      expect(request.claim_token).to be_nil
      expect(responses).not_to have_received(:create)
    end
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

  it "does not overwrite a running worker with an enqueue failure" do
    request = select_request
    token = request.claim!
    request.enqueue_failed!
    expect(request.reload.state).to eq("running")
    expect(request.claim_token).to eq(token)
  end

  [ :pointer, :token, :material ].each do |change|
    it "fences #{change} changes in the gap after the committed claim and before the API transaction" do
      request = select_request
      allow_any_instance_of(QuestionGenerationRequest).to receive(:claim!).and_wrap_original do |method|
        token = method.call
        case change
        when :pointer then select_request(model: "model-B")
        when :token then request.update!(claim_token: "different-token")
        when :material
          assignment.material_file.attach(io: StringIO.new("%PDF-1.4 replacement"), filename: "replacement.pdf", content_type: "application/pdf")
        end
        token
      end
      expect(generator.call(assignment)).to be_nil
      expect(request.reload.state).to eq("running")
      expect(assignment.questions.count).to eq(0)
      expect(responses).not_to have_received(:create)
    end
  end

  it "does not fan out a delayed success after a different request was selected" do
    request = select_request
    original_reading = submission.extracted_text
    allow(AiClient).to receive(:build).and_return(client)
    allow_any_instance_of(QuestionGenerator).to receive(:call).and_wrap_original do |method, *args, **options|
      result = method.call(*args, **options)
      select_request(model: "model-B")
      result
    end
    QuestionGenerationJob.perform_now(assignment, request.material_blob_id, request_id: request.id)
    expect(request.reload.state).to eq("succeeded")
    expect(submission.reload).to be_submitted
    expect(submission.extracted_text).to eq(original_reading)
    expect(AnswerGradingJob).not_to have_been_enqueued
  end

  it "retains successful questions if the worker is interrupted before fan-out, without replaying AI" do
    request = select_request
    submission.update!(status: :grading)
    allow(AiClient).to receive(:build).and_return(client)
    allow_any_instance_of(QuestionGenerator).to receive(:call).and_wrap_original do |method, *args, **options|
      method.call(*args, **options)
      raise Interrupt, "simulated worker interruption"
    end
    expect { QuestionGenerationJob.perform_now(assignment, request.material_blob_id, request_id: request.id) }.to raise_error(Interrupt)
    expect(request.reload.state).to eq("succeeded")
    expect(assignment.questions.count).to eq(1)
    expect(submission.reload).to be_grading
    expect(Recovery::SubmissionInspector.new.call(submission)[:question_generation][:state]).to eq("succeeded")
    expect(AnswerGradingJob).not_to have_been_enqueued
    expect(responses).to have_received(:create).once
  end

  it "does not adopt a replacement claim token for success fan-out" do
    request = select_request
    submission
    allow(AiClient).to receive(:build).and_return(client)
    allow_any_instance_of(QuestionGenerator).to receive(:call).and_wrap_original do |method, *args, **options|
      result = method.call(*args, **options)
      request.reload.update!(claim_token: "replacement-token")
      result
    end
    QuestionGenerationJob.perform_now(assignment, request.material_blob_id, request_id: request.id)
    expect(request.reload.state).to eq("succeeded")
    expect(submission.reload).to be_submitted
    expect(AnswerGradingJob).not_to have_been_enqueued
  end

  it "fences a late error recorded after rollback when the pointer has moved" do
    request = select_request
    submission
    allow(AiClient).to receive(:build).and_return(client)
    allow(responses).to receive(:create).and_raise("late error")
    allow_any_instance_of(QuestionGenerationRequest).to receive(:fail!).and_wrap_original do |method, **options|
      select_request(model: "model-B")
      method.call(**options)
    end
    QuestionGenerationJob.perform_now(assignment, request.material_blob_id, request_id: request.id)
    expect(request.reload.state).to eq("running")
    expect(assignment.reload.current_question_generation_request.state).to eq("pending")
    expect(submission.reload).to be_submitted
    expect(assignment.questions.count).to eq(0)
  end

  it "rolls back every question if committing success fails, then persists safe failure" do
    request = select_request
    allow_any_instance_of(QuestionGenerationRequest).to receive(:update!).and_wrap_original do |method, **attributes|
      raise "success save failed" if attributes[:state] == "succeeded"

      method.call(**attributes)
    end
    expect { generator.call(assignment) }.to raise_error("success save failed")
    expect(assignment.questions.count).to eq(0)
    expect(request.reload.state).to eq("failed")
    expect(request.failure_code).to eq("generation_failed")
  end

  it "keeps request input identity immutable after persistence" do
    request = select_request
    [ :assignment_id, :material_blob_id, :model, :prompt_version ].each do |attribute|
      replacement = attribute.to_s.end_with?("_id") ? 999_999 : "replacement"
      expect { request.update!(attribute => replacement) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      request.reload
    end
  end

  it "removes selected and historical requests only in the protected assignment deletion" do
    first = select_request
    first.update!(state: "failed", failure_code: "generation_failed")
    second = select_request(model: "model-B")
    expect(AssignmentDeletion.new.call(assignment, teacher: teacher)).to eq(:deleted)
    expect(QuestionGenerationRequest.where(id: [ first.id, second.id ])).not_to exist
    expect(Assignment.where(id: assignment.id)).not_to exist
  end

  it "rolls pointer and ledger deletion back if the authorized assignment deletion fails" do
    request = select_request
    allow(assignment).to receive(:destroy!).and_raise(ActiveRecord::RecordNotDestroyed)
    expect { AssignmentDeletion.new.call(assignment, teacher: teacher) }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(assignment.reload.current_question_generation_request_id).to eq(request.id)
    expect(request.reload.state).to eq("pending")
  end

  it "does not accept another assignment's selected request" do
    request = select_request
    other = Assignment.create!(teacher: teacher, title: "Other", point_per_question: 5)
    expect { other.update!(current_question_generation_request: request) }.to raise_error(ActiveRecord::RecordInvalid)
    expect { assignment.question_generation_requests.create!(material_blob_id: request.material_blob_id, model: request.model, prompt_version: request.prompt_version) }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
