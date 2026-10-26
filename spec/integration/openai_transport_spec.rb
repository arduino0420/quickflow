require "rails_helper"
require_relative "../support/ai_grading_context"
require_relative "../support/pdf_fixture_builder"

# Only the HTTP transport is replaced. Resources, serialization, response models,
# errors, output_text and AiClient's options all come from the installed gem.
RSpec.describe "Offline OpenAI SDK compatibility", type: :model do
  include_context "AI grading records"
  include PdfFixtureBuilder
  let(:generation_model) { AiClient::DEFAULT_MODEL }

  before do
    @requests = []
    @replies = []
    transport = Object.new
    requests, replies = @requests, @replies
    transport.define_singleton_method(:execute) do |request|
      body = request.body
      body = body.read if body.respond_to?(:read)
      body = body.to_a.join if body.respond_to?(:each) && !body.is_a?(String)
      requests << [ request, body ]
      reply = replies.shift or raise "Unexpected offline HTTP request"
      raise reply if reply.is_a?(Exception)

      status, data = reply
      OpenAI::HTTPClient::Response.new(status: status, headers: { "content-type" => "application/json" }, body: JSON.generate(data))
    end
    allow(OpenAI::Client).to receive(:new).and_wrap_original do |original, **options|
      expect(options[:max_retries]).to eq(0)
      expect(options[:timeout]).to eq(120)
      original.call(**options, http_client: transport)
    end
    @sdk = AiClient.build(api_key: "offline-nonfunctional")
    allow(AiClient).to receive(:build).and_return(@sdk)
    allow(AiFileCleanupJob).to receive(:schedule)
  end

  def response(data, status: "completed", refusal: false, error: nil)
    { id: "resp-offline", object: "response", created_at: 1, model: "offline-model", status: status,
      error: error, incomplete_details: status == "incomplete" ? { reason: "max_output_tokens" } : nil,
      output: [ { type: "message", id: "msg-offline", role: "assistant", status: "completed",
        content: refusal ? [ { type: "refusal", refusal: "synthetic refusal" } ] :
          [ { type: "output_text", text: JSON.generate(data), annotations: [] } ] } ] }
  end

  def upload_reply
    [ 200, { id: "file-offline", object: "file", bytes: 400, created_at: 1, filename: "synthetic.pdf", purpose: "user_data" } ]
  end

  def attach_answer
    submission.answer_file.attach(io: StringIO.new(valid_pdf_bytes), filename: "synthetic.pdf", content_type: "application/pdf")
  end

  def assert_upload
    request, body = @requests.first
    expect(request.url.path).to eq("/v1/files")
    expect(request.headers.values.join).to include("multipart/form-data")
    expect(body).to include("%PDF-1.4", "user_data", "expires_after", "created_at", "3600")
    expect(request.timeout).to be_between(119, 120)
  end

  it "reads a synthetic PDF using real multipart serialization and output_text" do
    attach_answer
    @replies.concat([ upload_reply, [ 200, response({ problems: [ problem ] }) ] ])
    reader = AnswerReader.new(client: @sdk)
    expect(JSON.parse(reader.call(submission))).to eq("problems" => [ problem.stringify_keys ])
    assert_upload
    body = JSON.parse(@requests.last.last)
    expect(body).to include("model" => AiClient::DEFAULT_MODEL, "store" => false)
    expect(body.dig("input", 0, "content", 1, "text")).to eq(reader.send(:prompt))
    expect(AiFileCleanupJob).to have_received(:schedule).with("file-offline")
  end

  %w[upload reading].each do |stage|
    it "recovers one #{stage} 5xx through the real SDK without nested retries" do
      attach_answer
      error = [ 503, { error: { message: "synthetic server failure", type: "server_error" } } ]
      success = [ 200, response({ problems: [ problem ] }) ]
      @replies.concat(stage == "upload" ? [ error, upload_reply, success ] : [ upload_reply, error, success ])
      allow_any_instance_of(AnswerReadingRequest).to receive(:sleep)

      data = AnswerReader.new(client: @sdk, retry_allowed: -> { true }).call(submission)
      expect(JSON.parse(data)).to eq("problems" => [ problem.stringify_keys ])
      expect(@requests.size).to eq(3)
      expect(@replies).to be_empty
      paths = @requests.map { |request, _| request.url.path }
      expect(paths.count("/v1/files")).to eq(stage == "upload" ? 2 : 1)
      expect(paths.count("/v1/responses")).to eq(stage == "reading" ? 2 : 1)
      expect(AiFileCleanupJob).to have_received(:schedule).with("file-offline").once
    end
  end

  [ "incomplete", "failed", "refused", "http_error", "timeout" ].each do |failure|
    it "rejects #{failure} and schedules PDF cleanup without an SDK retry" do
      attach_answer
      reply = case failure
      when "http_error" then [ 500, { error: { message: "synthetic", type: "server_error" } } ]
      when "timeout" then OpenAI::Errors::APITimeoutError.new(url: "https://offline.invalid")
      else
        [ 200, response({}, status: failure == "refused" ? "completed" : failure,
          refusal: failure == "refused", error: failure == "failed" ? { code: "server_error", message: "synthetic" } : nil) ]
      end
      @replies.concat([ upload_reply, reply ])
      expect { AnswerReader.new(client: @sdk).call(submission) }.to raise_error(StandardError)
      expect(@requests.size).to eq(2)
      expect(AiFileCleanupJob).to have_received(:schedule).with("file-offline")
    end
  end

  it "generates using the exact strict schema, instructions and real response classes" do
    generator = QuestionGenerator.new(client: @sdk)
    data = { questions: [ { question_label: "1", question_text: "1+1", correct_answer: "2", grading_rule: "sum", requires_work: false } ] }
    @replies.concat([ upload_reply, [ 200, response(data) ] ])
    expect(generator.call(assignment).first.correct_answer).to eq("2")
    body = JSON.parse(@requests.last.last)
    expect(body).to include("model" => AiClient::DEFAULT_MODEL, "store" => false, "instructions" => generator.send(:prompt))
    expect(body["text"]).to eq(JSON.parse(JSON.generate(format: { type: "json_schema", name: "generated_questions", strict: true, schema: generator.send(:response_schema) })))
    expect(AiFileCleanupJob).to have_received(:schedule).with("file-offline")
  end

  it "grades actual application input through the real output_text helper" do
    question = create_question
    @replies << [ 200, response({ results: [ judgment(question) ] }) ]
    grader = AnswerGrader.new(client: @sdk)
    expect(grader.call(submission, [ question ]).first[:ai_judgment]).to eq("correct")
    body = JSON.parse(@requests.last.last)
    expect(body).to include("store" => false, "model" => AiClient::DEFAULT_MODEL, "instructions" => grader.send(:prompt))
    expect(JSON.parse(body["input"]).dig("problems", 0, "student_answer")).to eq("5x")
  end

  [ "incomplete", "failed", "refused", "http_error", "invalid_json" ].each do |failure|
    [ "generation", "grading" ].each do |operation|
      it "rejects #{failure} during #{operation} with real SDK decoding" do
        content = response({}, status: failure == "incomplete" ? "incomplete" : failure == "failed" ? "failed" : "completed",
          refusal: failure == "refused", error: failure == "failed" ? { code: "server_error", message: "synthetic" } : nil)
        content[:output][0][:content][0][:text] = "invalid JSON" if failure == "invalid_json"
        reply = failure == "http_error" ? [ 500, { error: { message: "synthetic" } } ] : [ 200, content ]
        if operation == "generation"
          @replies.concat([ upload_reply, reply ])
          expect { QuestionGenerator.new(client: @sdk).call(assignment) }.to raise_error(StandardError)
          expect(assignment.questions.count).to eq(0)
          expect(assignment.question_generation_requests.last.reload.state).to eq("failed")
          expect(AiFileCleanupJob).to have_received(:schedule).with("file-offline")
          expect(@requests.size).to eq(2)
        else
          question = create_question
          @replies << reply
          expect { AnswerGrader.new(client: @sdk).call(submission, [ question ]) }.to raise_error(StandardError)
          expect(@requests.size).to eq(1)
        end
      end
    end
  end

  it "does not schedule cleanup for a failed upload or implicitly retry it" do
    attach_answer
    @replies << [ 500, { error: { message: "synthetic upload error" } } ]
    expect { AnswerReader.new(client: @sdk).call(submission) }.to raise_error(OpenAI::Errors::InternalServerError)
    expect(@requests.size).to eq(1)
    expect(AiFileCleanupJob).not_to have_received(:schedule)
  end

  [ [ 200, true, false ], [ 200, false, true ], [ 404, nil, false ], [ 500, nil, true ] ].each do |status, deleted, retry_job|
    it "handles deletion HTTP #{status} deleted=#{deleted.inspect} with only the explicit job retry" do
      @replies << [ status, status == 200 ? { id: "file-offline", object: "file", deleted: deleted } : { error: { message: "synthetic" } } ]
      allow(AiFileCleanupJob).to receive(:set).and_call_original
      AiFileCleanupJob.perform_now("file-offline")
      expect(@requests.size).to eq(1)
      expect(@requests.first.first.method).to eq(:delete)
      expect(@requests.first.first.url.path).to eq("/v1/files/file-offline")
      if retry_job
        expect(AiFileCleanupJob).to have_received(:set).with(wait: 1.minute)
      else
        expect(AiFileCleanupJob).not_to have_received(:set)
      end
    end
  end
end
