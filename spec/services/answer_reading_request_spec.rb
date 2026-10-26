require "rails_helper"

RSpec.describe AnswerReadingRequest do
  def api_error(status: 503, request_id: "req_safe", body: "PRIVATE ANSWER KEY")
    OpenAI::Errors::APIStatusError.for(url: URI("https://example.invalid/private"), status: status,
      headers: { "x-request-id" => request_id }, body: body, request: nil, response: nil)
  end

  before do
    @now = 0.0
    @delays = []
    @allowed = true
    @requests = described_class.new(retry_allowed: -> { @allowed }, clock: -> { @now },
      sleeper: ->(seconds) { @delays << seconds; @now += seconds })
    allow(Rails.logger).to receive(:warn)
  end

  it "backs off once for explicit 5xx and disables SDK retries on each request" do
    calls = []
    result = @requests.call("reading") do |options|
      calls << options
      raise api_error if calls.size == 1

      :recovered
    end
    expect(result).to eq(:recovered)
    expect(calls).to eq([ { max_retries: 0, timeout: 120.0 } ] * 2)
    expect(@delays).to eq([ 1.0 ])
  end

  it "shares one extra-attempt budget across upload and reading" do
    uploads = readings = 0
    @requests.call("upload") { uploads += 1; raise api_error if uploads == 1; :uploaded }
    expect { @requests.call("reading") { readings += 1; raise api_error } }.to raise_error(OpenAI::Errors::InternalServerError)
    expect([ uploads, readings ]).to eq([ 2, 1 ])
    expect(@delays).to eq([ 1.0 ])
  end

  it "stops persistent 5xx after the second request" do
    attempts = 0
    expect { @requests.call("reading") { attempts += 1; raise api_error } }.to raise_error(OpenAI::Errors::InternalServerError)
    expect(attempts).to eq(2)
  end

  [ 400, 401, 403, 422, 429 ].each do |status|
    it "does not retry HTTP #{status}" do
      attempts = 0
      expect { @requests.call("upload") { attempts += 1; raise api_error(status: status) } }.to raise_error(OpenAI::Errors::APIStatusError)
      expect(attempts).to eq(1)
      expect(@delays).to be_empty
    end
  end

  [ OpenAI::Errors::APITimeoutError, OpenAI::Errors::APIConnectionError ].each do |klass|
    it "does not retry unknown outcomes from #{klass}" do
      error = klass.new(url: URI("https://example.invalid"), message: "PRIVATE ANSWER")
      attempts = 0
      expect { @requests.call("reading") { attempts += 1; raise error } }.to raise_error(klass)
      expect(attempts).to eq(1)
      expect(@delays).to be_empty
    end
  end

  it "does not retry without an ownership check" do
    request = described_class.new
    attempts = 0
    expect { request.call("reading") { attempts += 1; raise api_error } }.to raise_error(OpenAI::Errors::InternalServerError)
    expect(attempts).to eq(1)
  end

  it "rechecks ownership after backoff and before a retry" do
    request = described_class.new(retry_allowed: -> { @allowed }, sleeper: ->(_) { @allowed = false })
    attempts = 0
    expect { request.call("reading") { attempts += 1; raise api_error } }.to raise_error(described_class::OwnershipLost)
    expect(attempts).to eq(1)
  end

  it "bounds the next request by the remaining total budget" do
    @requests.call("upload") { @now = 239.0; :uploaded }
    options = nil
    @requests.call("reading") { |value| options = value }
    expect(options).to eq(max_retries: 0, timeout: 2.0)
    @now = 242.0
    expect { @requests.call("reading") { raise "must not call API" } }.to raise_error(described_class::DeadlineExceeded)
  end

  it "logs only stage/status/bounded safe request ID and retry outcome" do
    @requests.call("upload") { :ok }
    expect { @requests.call("reading") { raise api_error(request_id: "PRIVATE\nINJECTION") } }.to raise_error(OpenAI::Errors::InternalServerError)
    expect(Rails.logger).to have_received(:warn).with("AnswerReadingAPI stage=reading attempt=1 status=503 request_id=unavailable outcome=retry_once")
    expect(Rails.logger).to have_received(:warn).with("AnswerReadingAPI stage=reading attempt=2 status=503 request_id=unavailable outcome=stop")
    expect(Rails.logger).not_to have_received(:warn).with(/PRIVATE|example\.invalid|KEY/)
  end

  it "keeps a safe provider request ID for later diagnosis" do
    expect { @requests.call("reading") { raise api_error(request_id: "req_abc-123") } }.to raise_error(OpenAI::Errors::InternalServerError)
    expect(Rails.logger).to have_received(:warn).with(/request_id=req_abc-123/).twice
  end
end
