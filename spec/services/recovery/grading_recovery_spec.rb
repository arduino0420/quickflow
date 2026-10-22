require "rails_helper"
require_relative "../../support/ai_grading_context"

RSpec.describe Recovery::GradingRecovery do
  include_context "AI grading records"

  let(:service) { described_class.new }

  before do
    allow(ActiveJob::Base).to receive(:queue_adapter_name).and_return(:solid_queue)
    submission.answer_file.attach(io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      filename: "answer.pdf", content_type: "application/pdf")
    question = create_question
    question.update!(grading_rule: JSON.generate(criteria: "同類項をまとめる。", requires_work: false,
      material_blob_id: assignment.material_file.blob.id))
    submission.update!(status: :failed)
  end

  it "increments the generation and enqueues only once" do
    expect(AnswerGradingJob).to receive(:perform_later).with(have_attributes(id: submission.id), 1, admission: kind_of(String)).and_return(true)
    expect(service.call(submission.id)).to eq(result: "enqueued", reason_codes: [])
    expect(submission.reload).to be_grading
    expect(submission.processing_generation).to eq(1)
    expect(service.call(submission.id)[:result]).to eq("ineligible")
  end

  [ false, nil ].each do |enqueue_result|
    it "returns to failed when enqueue returns #{enqueue_result.inspect}" do
      allow(AnswerGradingJob).to receive(:perform_later).and_return(enqueue_result)
      expect(service.call(submission.id)).to eq(result: "indeterminate", reason_codes: [ "enqueue_failed" ])
      expect(submission.reload).to be_failed
      expect(submission.processing_generation).to eq(1)
    end
  end

  it "does not overwrite a newer generation after an enqueue exception" do
    allow(AnswerGradingJob).to receive(:perform_later) do
      submission.update!(processing_generation: 2)
      raise "queue unavailable"
    end
    service.call(submission.id)
    expect(submission.reload).to be_grading
    expect(submission.processing_generation).to eq(2)
  end

  it "refuses results or teacher judgments without changing them" do
    result = submission.grading_results.create!(question: assignment.questions.sole,
      ai_judgment: :correct, teacher_judgment: :incorrect, ai_model_name: "test",
      prompt_version: "v1", graded_at: Time.current)
    expect(AnswerGradingJob).not_to receive(:perform_later)
    expect(service.call(submission.id)[:result]).to eq("ineligible")
    expect(result.reload).to be_teacher_judgment_incorrect
    expect(submission.reload).to be_failed
  end

  it "refuses a state change during PDF verification" do
    allow_any_instance_of(Recovery::GradingEligibility).to receive(:inspect_pdf).and_wrap_original do |original, pdf|
      outcome = original.call(pdf)
      submission.update!(processing_generation: 1) if submission.reload.processing_generation.zero?
      outcome
    end
    expect(AnswerGradingJob).not_to receive(:perform_later)
    expect(service.call(submission.id)).to eq(result: "indeterminate", reason_codes: [ "state_changed" ])
    expect(submission.reload).to be_failed
  end

  it "refuses an interrupted grading run when the queue cannot be verified" do
    submission.update!(status: :grading, processing_generation: 1)
    allow(service).to receive(:queue_clear?).and_return(false)
    expect(AnswerGradingJob).not_to receive(:perform_later)
    expect(service.call(submission.id, interrupted_generation: 1)).to eq(
      result: "indeterminate", reason_codes: [ "grading_job_present_or_unknown" ])
    expect(submission.reload.processing_generation).to eq(1)
  end

  it "advances a stranded generation when the queue is verifiably clear" do
    submission.update!(status: :grading, processing_generation: 1)
    allow(service).to receive(:queue_clear?).and_return(true)
    expect(AnswerGradingJob).to receive(:perform_later).with(have_attributes(id: submission.id), 2, admission: kind_of(String)).and_return(true)
    expect(service.call(submission.id, interrupted_generation: 1)[:result]).to eq("enqueued")
    expect(submission.reload.processing_generation).to eq(2)
  end

  it "restarts a grading answer only after checking the current generation" do
    submission.update!(status: :grading, processing_generation: 1)
    allow(service).to receive(:queue_clear?).and_return(true)
    expect(AnswerGradingJob).to receive(:perform_later).with(have_attributes(id: submission.id), 2, admission: kind_of(String)).and_return(true)
    expect(service.call(submission.id, interrupted_generation: 1)[:result]).to eq("enqueued")
    expect(service.call(submission.id, interrupted_generation: 1)).to eq(
      result: "indeterminate", reason_codes: [ "generation_changed" ])
  end

  it "returns a stopped-page hint only when no related queue job is visible" do
    submission.update!(status: :grading)
    allow(service).to receive(:queue_clear?).with(submission.id, assignment.id).and_return(true)
    expect(service.stopped_grading_candidate?(submission)).to be(true)
    allow(service).to receive(:queue_clear?).with(submission.id, assignment.id).and_return(false)
    expect(service.stopped_grading_candidate?(submission)).to be(false)
  end

  it "returns a stopped-page hint as false without saved answers" do
    submission.update!(status: :grading)
    Question.where(assignment: assignment).delete_all
    expect(service).not_to receive(:queue_clear?)
    expect(service.stopped_grading_candidate?(submission)).to be(false)
  end

  it "restores an interrupted grading retry to failed if enqueue fails" do
    submission.update!(status: :grading, processing_generation: 1)
    allow(service).to receive(:queue_clear?).and_return(true)
    allow(AnswerGradingJob).to receive(:perform_later).and_return(false)
    expect(service.call(submission.id, interrupted_generation: 1)).to eq(
      result: "indeterminate", reason_codes: [ "enqueue_failed" ])
    expect(submission.reload).to be_failed
    expect(submission.processing_generation).to eq(2)
  end

  it "leaves a recoverable grading state if the process stops after the state commit" do
    allow(AnswerGradingJob).to receive(:perform_later).and_raise(SystemExit)
    expect { service.call(submission.id) }.to raise_error(SystemExit)
    expect(submission.reload).to be_grading
    expect(submission.processing_generation).to eq(1)
    expect(submission.grading_results).to be_empty

    allow(service).to receive(:queue_clear?).and_return(true)
    expect(AnswerGradingJob).to receive(:perform_later).with(have_attributes(id: submission.id), 2, admission: kind_of(String)).and_return(true)
    expect(service.call(submission.id, interrupted_generation: 1)[:result]).to eq("enqueued")
    expect(submission.reload.processing_generation).to eq(2)
  end

  it "treats a queued job for the same submission as active" do
    job = double(class_name: "AnswerGradingJob", arguments: { "arguments" => [ { "_aj_globalid" => "gid://quickflow/Submission/#{submission.id}" }, 1 ] })
    relation = double
    allow(relation).to receive(:find_each).and_yield(job)
    stub_const("SolidQueue::Job", Class.new { def self.where(*) = nil })
    allow(SolidQueue::Job).to receive(:where).and_return(relation)
    expect(service.send(:queue_clear?, submission.id, assignment.id)).to be(false)
  end

  it "refuses an unreadable queue entry or queue failure" do
    relation = double
    allow(relation).to receive(:find_each).and_yield(double(arguments: {}))
    stub_const("SolidQueue::Job", Class.new { def self.where(*) = nil })
    allow(SolidQueue::Job).to receive(:where).and_return(relation)
    expect(service.send(:queue_clear?, submission.id, assignment.id)).to be(false)
    allow(SolidQueue::Job).to receive(:where).and_raise("queue unavailable")
    expect(service.send(:queue_clear?, submission.id, assignment.id)).to be(false)
  end

  [ "AnswerReadingJob", "AnswerGradingJob", "QuestionGenerationJob" ].each do |job_class|
    it "refuses an unfinished #{job_class} for the answer or its assignment" do
      owner = job_class == "QuestionGenerationJob" ? assignment : submission
      job = double(class_name: job_class, arguments: { "arguments" => [ { "_aj_globalid" => "gid://quickflow/#{owner.class.name}/#{owner.id}" } ] })
      relation = double
      allow(relation).to receive(:find_each).and_yield(job)
      stub_const("SolidQueue::Job", Class.new { def self.where(*) = nil })
      allow(SolidQueue::Job).to receive(:where).and_return(relation)
      expect(service.send(:queue_clear?, submission.id, assignment.id)).to be(false)
    end
  end

  it "does not infer a stopped job if Solid Queue is not the active adapter" do
    allow(ActiveJob::Base).to receive(:queue_adapter_name).and_return(:test)
    stub_const("SolidQueue::Job", Class.new { def self.where(*) = nil })
    expect(SolidQueue::Job).not_to receive(:where)
    expect(service.send(:queue_clear?, submission.id, assignment.id)).to be(false)
  end
end
