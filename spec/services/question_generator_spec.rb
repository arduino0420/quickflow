require "rails_helper"
require_relative "../support/ai_grading_context"

RSpec.describe QuestionGenerator, type: :model do
  include_context "AI grading records"

  let(:generated_question) do
    { question_label: "1(1)", question_text: problem[:question_text], correct_answer: "5x",
      grading_rule: "同類項をまとめる。", requires_work: false }
  end
  let(:response) { ai_response({ questions: [ generated_question ] }, model: "actual-generator-model") }
  let(:generator) { described_class.new(client: client, model: "configured-generator-model") }

  before do
    allow(files).to receive(:create).and_return(double(id: "file-material"))
    allow(responses).to receive(:create).and_return(response)
  end

  it "generates and saves questions with their rules and actual model once" do
    questions = generator.call(assignment)

    expect(questions.size).to eq(1)
    question = questions.first.reload
    expect(question.correct_answer).to eq("5x")
    expect(JSON.parse(question.grading_rule)).to eq("criteria" => "同類項をまとめる。", "requires_work" => false,
      "material_blob_id" => assignment.material_file.blob.id)
    expect(question.answer_generation_model).to eq("actual-generator-model")
    expect(question.answer_generation_prompt_version).to eq(described_class::PROMPT_VERSION)
    expect(question.answer_generated_at).to be_present
    expect(question.position).to eq(1)
    expect(responses).to have_received(:create).once.with(hash_including(model: "configured-generator-model"))
    expect(generator.call(assignment).map(&:id)).to eq(questions.map(&:id))
    expect(files).to have_received(:create).once
    expect(responses).to have_received(:create).once
  end

  it "reuses persisted questions without constructing a client or needing the PDF" do
    question = create_question
    expect(AiClient).not_to receive(:build)
    expect(described_class.new.call(Assignment.find(assignment.id))).to eq([ question ])
  end

  [ :completed, "completed" ].each do |status|
    it "saves a completed response represented as #{status.inspect}" do
      allow(response).to receive(:status).and_return(status)
      expect(generator.call(assignment).first.correct_answer).to eq("5x")
      expect(responses).to have_received(:create).once
    end
  end

  it "accepts completed status converted by the actual SDK without any network request" do
    sdk_response = OpenAI::Internal::Type::Converter.coerce(OpenAI::Models::Responses::Response, {
      status: "completed", model: "sdk-model", output: [
        { type: "message", id: "msg-test", role: "assistant", status: "completed",
          content: [ { type: "output_text", text: JSON.generate(questions: [ generated_question ]), annotations: [] } ] }
      ]
    })
    expect(sdk_response.status).to eq(:completed)
    allow(responses).to receive(:create).and_return(sdk_response)
    expect(generator.call(assignment).first.correct_answer).to eq("5x")
  end

  context "failure diagnostics" do
    before { allow(Rails.logger).to receive(:error) }

    [ :incomplete, :failed ].each do |status|
      it "records safe metadata for #{status} without parsing or saving or retrying" do
        allow(response).to receive_messages(status: status, id: "resp-test",
          incomplete_details: double(reason: :max_output_tokens),
          error: double(code: :server_error, message: "PRIVATE ERROR MESSAGE"),
          usage: double(input_tokens: 123, output_tokens: 45))
        expect(response).not_to receive(:output_text)
        expect { generator.call(assignment) }.to raise_error(/response is not completed/)
        expect(assignment.questions).to be_empty
        expect(Rails.logger).to have_received(:error).with("Question generation failed: #{JSON.generate(
          assignment_id: assignment.id, material_blob_id: assignment.material_file.blob.id,
          response_id: "resp-test", model: "actual-generator-model", status: status.to_s,
          incomplete_reason: "max_output_tokens", error_code: "server_error", input_tokens: 123, output_tokens: 45
        )}")
        expect(responses).to have_received(:create).once
      end
    end

    it "logs nil diagnostic fields without losing the original error" do
      allow(response).to receive_messages(status: nil, model: nil)
      expect { generator.call(assignment) }.to raise_error(/response is not completed/)
      expect(Rails.logger).to have_received(:error).with("Question generation failed: #{JSON.generate(
        assignment_id: assignment.id, material_blob_id: assignment.material_file.blob.id,
        response_id: nil, model: "configured-generator-model", status: nil, incomplete_reason: nil,
        error_code: nil, input_tokens: nil, output_tokens: nil
      )}")
    end

    it "logs an API failure with no response without recording the exception message" do
      allow(responses).to receive(:create).and_raise("PRIVATE API KEY AND PDF TEXT")
      expect { generator.call(assignment) }.to raise_error("PRIVATE API KEY AND PDF TEXT")
      expect(Rails.logger).to have_received(:error).with(/"response_id":null/)
      expect(Rails.logger).not_to have_received(:error).with(/PRIVATE/)
    end

    it "does not log output text when JSON parsing fails" do
      allow(response).to receive(:output_text).and_return("PRIVATE AI RESPONSE AND STUDENT ANSWER")
      expect { generator.call(assignment) }.to raise_error(JSON::ParserError)
      expect(Rails.logger).to have_received(:error).with(/"status":"completed"/)
      expect(Rails.logger).not_to have_received(:error).with(/PRIVATE/)
    end

    it "preserves the generation error if the logger fails" do
      allow(response).to receive(:status).and_return(:failed)
      allow(Rails.logger).to receive(:error).and_raise("Logger failed")
      expect { generator.call(assignment) }.to raise_error(/response is not completed/)
    end
  end

  it "requests a strict schema matching the existing question fields and allowing uncertain values" do
    generator.call(assignment)
    expect(responses).to have_received(:create).with(hash_including(text: {
      format: { type: "json_schema", name: "generated_questions", strict: true, schema: {
        type: "object", additionalProperties: false, required: [ "questions" ],
        properties: { questions: { type: "array", items: {
          type: "object", additionalProperties: false,
          required: %w[question_label question_text correct_answer grading_rule requires_work],
          properties: {
            "question_label" => { type: [ "string", "null" ] }, "question_text" => { type: [ "string", "null" ] },
            "correct_answer" => { type: [ "string", "null" ] }, "grading_rule" => { type: [ "string", "null" ] },
            "requires_work" => { type: "boolean" }
          }
        } } }
      } }
    }))
  end

  it "preserves mathematical symbols, fractions and quoted text without correction" do
    text = '⅘ ÷ (4/3) × −x²; "a"; \\frac{4}{3}; .replace("⅘","(4/3)")'
    allow(responses).to receive(:create).and_return(ai_response(questions: [
      generated_question.merge(question_text: text, correct_answer: text, grading_rule: text)
    ]))
    question = generator.call(assignment).first.reload
    expect(question.question_text).to eq(text)
    expect(question.correct_answer).to eq(text)
    expect(JSON.parse(question.grading_rule).fetch("criteria")).to eq(text)
  end

  context "when the response cannot be safely parsed" do
    around do |example|
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rails.cache = original_cache
    end

    it "rejects the reported replacement expression without repair, saving, grading or another API request" do
      # Reproduce the reported syntax; the original full response was not saved.
      invalid_json = '{"questions":[{"question_text":"⅘".replace("⅘","(4/3)"),"correct_answer":"x"}]}'
      allow(response).to receive(:output_text).and_return(invalid_json)
      expect(AnswerGradingJob).not_to receive(:perform_later)
      expect { generator.call(assignment) }.to raise_error(JSON::ParserError, /replace/)
      expect { generator.call(Assignment.find(assignment.id)) }.to raise_error(/automatic reattempt is disabled/)
      expect(assignment.questions).to be_empty
      expect(files).to have_received(:create).once
      expect(responses).to have_received(:create).once
    end

    %w[incomplete failed queued in_progress cancelled].each do |status|
      it "stops before parsing a #{status} response and does not retry" do
        allow(response).to receive(:status).and_return(status)
        expect(response).not_to receive(:output_text)
        expect { generator.call(assignment) }.to raise_error(/response is not completed/)
        expect { generator.call(Assignment.find(assignment.id)) }.to raise_error(/automatic reattempt is disabled/)
        expect(assignment.questions).to be_empty
        expect(files).to have_received(:create).once
        expect(responses).to have_received(:create).once
      end
    end

    it "stops before parsing a refusal even when the response is completed" do
      allow(response).to receive(:output).and_return([ double(content: [ double(type: "refusal") ]) ])
      expect(response).not_to receive(:output_text)
      expect { generator.call(assignment) }.to raise_error(/response was refused/)
      expect { generator.call(assignment) }.to raise_error(/automatic reattempt is disabled/)
      expect(assignment.questions).to be_empty
      expect(responses).to have_received(:create).once
    end

    it "rejects a refusal converted by the actual SDK without parsing, saving or retrying" do
      refusal = OpenAI::Internal::Type::Converter.coerce(OpenAI::Models::Responses::ResponseOutputRefusal,
        { type: "refusal", refusal: "PRIVATE REFUSAL TEXT" })
      expect(refusal.type).to eq(:refusal)
      allow(response).to receive(:output).and_return([ double(content: [ refusal ]) ])
      expect(response).not_to receive(:output_text)
      expect { generator.call(assignment) }.to raise_error(/response was refused/)
      expect { generator.call(assignment) }.to raise_error(/automatic reattempt is disabled/)
      expect(assignment.questions).to be_empty
      expect(responses).to have_received(:create).once
    end

    it "accepts completed text output alongside reasoning output" do
      allow(response).to receive(:output).and_return([ double(type: "reasoning"), double(content: [ double(type: "output_text") ]) ])
      expect(generator.call(assignment).size).to eq(1)
    end
  end

  it "does not generate answers through the read-only path when no questions exist" do
    expect(AiClient).not_to receive(:build)
    expect(generator.saved_questions(assignment)).to eq([])
    expect(files).not_to have_received(:create)
    expect(responses).not_to have_received(:create)
  end

  it "rejects a queued generation for a replaced PDF before any API call" do
    expected_blob_id = assignment.material_file.blob.id
    assignment.material_file.attach(io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      filename: "replacement.pdf", content_type: "application/pdf")
    expect { generator.call(assignment, material_blob_id: expected_blob_id) }.to raise_error(/Material PDF has changed/)
    expect(files).not_to have_received(:create)
    expect(responses).not_to have_received(:create)
  end

  it "does not reuse or regenerate answers from a different source PDF" do
    generator.call(assignment)
    assignment.material_file.attach(io: StringIO.new(File.binread(Rails.root.join("spec/fixtures/files/material.pdf"))),
      filename: "replacement.pdf", content_type: "application/pdf")
    expect { generator.saved_questions(assignment) }.to raise_error(/Material PDF has changed/)
    expect { generator.call(assignment) }.to raise_error(/Material PDF has changed/)
    expect(files).to have_received(:create).once
    expect(responses).to have_received(:create).once
    expect(assignment.questions.count).to eq(1)
  end

  it "reuses a complete saved set with work requirements and an older prompt version" do
    first = create_question
    second = create_question(position: 2, label: "1(2)", requires_work: true)
    expect(AiClient).not_to receive(:build)
    expect(generator.call(assignment).map(&:id)).to eq([ first.id, second.id ])
    expect(files).not_to have_received(:create)
    expect(responses).not_to have_received(:create)
  end

  [ :question_label, :question_text, :correct_answer, :answer_generation_model, :answer_generation_prompt_version ].each do |attribute|
    it "stops on an incomplete saved #{attribute} without regenerating or deleting it" do
      question = create_question
      question.update_columns(attribute => " ")
      expect { generator.call(assignment) }.to raise_error(/Invalid saved questions/)
      expect(question.reload.public_send(attribute)).to eq(" ")
      expect(files).not_to have_received(:create)
      expect(responses).not_to have_received(:create)
    end
  end

  [ nil, "plain text", "[]", "null", '{"criteria":"","requires_work":false}',
    '{"criteria":42,"requires_work":false}', '{"criteria":"条件"}',
    '{"criteria":"条件","requires_work":"false"}' ].each do |rule|
    it "rejects invalid saved grading conditions #{rule.inspect} without API calls" do
      create_question.update_columns(grading_rule: rule)
      expect { generator.call(assignment) }.to raise_error(/automatic regeneration is disabled/)
      expect(files).not_to have_received(:create)
      expect(responses).not_to have_received(:create)
    end
  end

  it "detects a gap in saved question positions without regenerating" do
    create_question
    create_question(position: 3, label: "1(3)")
    expect { generator.call(assignment) }.to raise_error(/Invalid saved questions/)
    expect(assignment.questions.count).to eq(2)
    expect(files).not_to have_received(:create)
    expect(responses).not_to have_received(:create)
  end

  it "rejects repeated saved question labels without regenerating" do
    create_question
    create_question(position: 2)
    expect { generator.call(assignment) }.to raise_error(/Invalid saved questions/)
    expect(files).not_to have_received(:create)
    expect(responses).not_to have_received(:create)
  end

  it "stores the complete set in PDF order and keeps work requirements" do
    second = generated_question.merge(question_label: "1(2)", requires_work: true)
    allow(responses).to receive(:create).and_return(ai_response(questions: [ generated_question, second ]))

    questions = generator.call(assignment)
    expect(questions.map(&:position)).to eq([ 1, 2 ])
    expect(JSON.parse(questions.last.grading_rule)["requires_work"]).to be(true)
  end

  [ nil, "", " " ].each do |answer|
    it "does not guess or save an uncertain answer #{answer.inspect}" do
      allow(responses).to receive(:create).and_return(ai_response(questions: [ generated_question.merge(correct_answer: answer) ]))
      expect { generator.call(assignment) }.to raise_error("Invalid question generation result")
      expect(assignment.questions.count).to eq(0)
      expect(responses).to have_received(:create).once
    end
  end

  it "rejects duplicate question labels without saving partial questions" do
    allow(responses).to receive(:create).and_return(ai_response(questions: [ generated_question, generated_question ]))
    expect { generator.call(assignment) }.to raise_error("Invalid question generation result")
    expect(assignment.questions.count).to eq(0)
  end

  [ { questions: [] }, { questions: "bad" }, [], { questions: [ { question_label: "1" } ] } ].each do |data|
    it "rejects invalid generation structure #{data.inspect}" do
      allow(responses).to receive(:create).and_return(ai_response(data))
      expect { generator.call(assignment) }.to raise_error("Invalid question generation result")
      expect(assignment.questions.count).to eq(0)
    end
  end

  it "rolls back earlier questions if a later save fails" do
    second = generated_question.merge(question_label: "1(2)")
    allow(responses).to receive(:create).and_return(ai_response(questions: [ generated_question, second ]))
    allow_any_instance_of(Question).to receive(:save!).and_wrap_original do |original, *args, **kwargs|
      raise ActiveRecord::RecordInvalid.new(original.receiver) if original.receiver.position == 2

      original.call(*args, **kwargs)
    end
    expect { generator.call(assignment) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(assignment.questions.count).to eq(0)
  end

  it "rejects non-PDF material before calling the API" do
    assignment.material_file.attach(io: StringIO.new("text"), filename: "material.txt", content_type: "text/plain")
    expect { generator.call(assignment) }.to raise_error("Material is not a PDF")
    expect(files).not_to have_received(:create)
    expect(responses).not_to have_received(:create)
  end

  it "reports an API error without retrying or saving questions" do
    allow(responses).to receive(:create).and_raise(StandardError, "API failed")
    expect { generator.call(assignment) }.to raise_error("API failed")
    expect(assignment.questions.count).to eq(0)
    expect(responses).to have_received(:create).once
  end

  context "when generation has already failed" do
    around do |example|
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rails.cache = original_cache
    end

    it "does not repeat API calls for another submission while the failure is cached" do
      allow(responses).to receive(:create).and_raise(StandardError, "API failed")
      expect { generator.call(assignment) }.to raise_error("API failed")
      expect { generator.call(Assignment.find(assignment.id)) }.to raise_error(/automatic reattempt is disabled/)
      expect(files).to have_received(:create).once
      expect(responses).to have_received(:create).once
      expect(assignment.questions).to be_empty
    end

    [ :upload, :generation ].each do |stage|
      it "does not retry a #{stage} timeout or save partial questions" do
        error = OpenAI::Errors::APITimeoutError.new(url: URI("https://example.invalid"), message: "Timed out")
        resource = stage == :upload ? files : responses
        allow(resource).to receive(:create).and_raise(error)
        expect { generator.call(assignment) }.to raise_error(OpenAI::Errors::APITimeoutError)
        expect { generator.call(Assignment.find(assignment.id)) }.to raise_error(/automatic reattempt is disabled/)
        expect(files).to have_received(:create).once
        if stage == :upload
          expect(responses).not_to have_received(:create)
        else
          expect(responses).to have_received(:create).once
        end
        expect(assignment.questions).to be_empty
      end
    end

    it "allows an explicitly changed model to make a new generation attempt" do
      allow(responses).to receive(:create).and_raise(StandardError, "API failed")
      expect { generator.call(assignment) }.to raise_error("API failed")
      allow(responses).to receive(:create).and_return(response)
      expect(described_class.new(client: client, model: "another-model").call(assignment).size).to eq(1)
      expect(responses).to have_received(:create).twice
    end
  end
end
