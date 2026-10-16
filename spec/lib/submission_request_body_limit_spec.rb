require "rails_helper"

RSpec.describe SubmissionRequestBodyLimit do
  it "rejects a declared oversized body before reading it" do
    input = instance_double(StringIO)
    env = {
      "REQUEST_METHOD" => "POST", "PATH_INFO" => "/student/assignments/12/submission",
      "CONTENT_LENGTH" => (described_class::MAX_BYTES + 1).to_s, "rack.input" => input
    }
    app = ->(_request) { raise "oversized body reached Rails" }

    expect(input).not_to receive(:read)
    status, headers, = described_class.new(app).call(env)
    expect(status).to eq(413)
    expect(headers["cache-control"]).to eq("no-store")
  end

  it "counts streamed bodies and accepts the exact limit" do
    input = StringIO.new("x" * described_class::MAX_BYTES)
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/student/assignments/12/submission",
      "CONTENT_LENGTH" => "", "rack.input" => input }
    app = lambda do |request|
      body = +""
      while (chunk = request["rack.input"].read(64 * 1024))
        body << chunk
      end
      [ 200, {}, [ body.bytesize.to_s ] ]
    end

    status, _headers, body = described_class.new(app).call(env)
    expect(status).to eq(200)
    expect(body.join).to eq(described_class::MAX_BYTES.to_s)

    input = StringIO.new("x" * (described_class::MAX_BYTES + 1))
    env["rack.input"] = input
    app = ->(request) { request["rack.input"].read; [ 200, {}, [] ] }
    status, = described_class.new(app).call(env)
    expect(status).to eq(413)
  end

  it "does not limit other paths or methods" do
    input = StringIO.new("outside the submission route")
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/student/assignments/12/answer_draft",
      "CONTENT_LENGTH" => (described_class::MAX_BYTES + 1).to_s, "rack.input" => input }
    app = ->(request) { [ 200, {}, [ request["rack.input"].read ] ] }

    status, _headers, body = described_class.new(app).call(env)
    expect(status).to eq(200)
    expect(body.join).to eq("outside the submission route")
  end
end
