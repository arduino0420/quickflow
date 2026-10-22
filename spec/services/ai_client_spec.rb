require "rails_helper"

RSpec.describe AiClient do
  around do |example|
    keys = %w[OPENAI_MODEL OPENAI_ANSWER_READING_MODEL OPENAI_QUESTION_GENERATION_MODEL OPENAI_ANSWER_GRADING_MODEL OPENAI_TIMEOUT_SECONDS]
    original = keys.to_h { |key| [ key, ENV[key] ] }
    keys.each { |key| ENV.delete(key) }
    example.run
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  it "preserves the old model unless a model is configured" do
    expect(described_class.model(:answer_grading)).to eq("gpt-6-astra")
  end

  it "allows independent task models with a shared fallback" do
    ENV["OPENAI_MODEL"] = "shared-model"
    ENV["OPENAI_ANSWER_GRADING_MODEL"] = "grading-model"
    ENV["OPENAI_QUESTION_GENERATION_MODEL"] = "generation-model"
    expect(described_class.model(:answer_reading)).to eq("shared-model")
    expect(described_class.model(:answer_grading)).to eq("grading-model")
    expect(described_class.model(:question_generation)).to eq("generation-model")
  end

  it "rejects a blank configured model" do
    ENV["OPENAI_MODEL"] = " "
    expect { described_class.model(:answer_grading) }.to raise_error("OpenAI model is not configured")
  end

  it "disables SDK retries and bounds each request to 120 seconds using a stub client" do
    client = instance_double(OpenAI::Client)
    expect(OpenAI::Client).to receive(:new).with(api_key: "test-key", max_retries: 0, timeout: 120).and_return(client)
    expect(described_class.build(api_key: "test-key")).to eq(client)
  end

  it "allows a configured timeout while keeping retries disabled" do
    ENV["OPENAI_TIMEOUT_SECONDS"] = "45.5"
    client = instance_double(OpenAI::Client)
    expect(OpenAI::Client).to receive(:new).with(api_key: "test-key", max_retries: 0, timeout: 45.5).and_return(client)
    expect(described_class.build(api_key: "test-key")).to eq(client)
  end

  [ "", "bad", "0", "-1", "Infinity", "NaN" ].each do |value|
    it "rejects an invalid timeout #{value.inspect} before constructing a client" do
      ENV["OPENAI_TIMEOUT_SECONDS"] = value
      expect(OpenAI::Client).not_to receive(:new)
      expect { described_class.build(api_key: "test-key") }.to raise_error("OpenAI timeout must be a positive number of seconds")
    end
  end
end
