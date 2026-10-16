require "rails_helper"

RSpec.describe SubmissionRequestBodyLimit do
  it "rejects oversized bodies on every Rails submission route variant before reading them" do
    paths = %w[
      /student/assignments/12/submission
      /student/assignments/12/submission/
      /student/assignments/12/submission.json
      /student/assignments/12/submission.xml/
      /student//assignments/12//submission//
      /student/assignments/quiz-12/submission
      /student/assignments/a%2Fb/submission
    ]
    app = ->(_request) { raise "oversized body reached Rails" }

    paths.each do |path|
      route = Rails.application.routes.recognize_path(path, method: :post)
      expect(route.slice(:controller, :action)).to eq(controller: "student/submissions", action: "create")
      input = instance_double(StringIO)
      expect(input).not_to receive(:read)
      env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => path,
        "CONTENT_LENGTH" => (described_class::MAX_BYTES + 1).to_s, "rack.input" => input }

      expect(described_class.new(app).call(env).first).to eq(413), path
      expect(env["PATH_INFO"]).to eq(path)
    end
  end

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

  it "bounds a format and trailing slash variant without Content-Length" do
    path = "/student/assignments/12/submission.json/"
    input = StringIO.new("x" * (described_class::MAX_BYTES + 1))
    env = { "REQUEST_METHOD" => "POST", "PATH_INFO" => path, "CONTENT_LENGTH" => "", "rack.input" => input }
    app = ->(request) { request["rack.input"].read; [ 200, {}, [] ] }

    expect(described_class.new(app).call(env).first).to eq(413)
    expect(input.pos).to eq(described_class::MAX_BYTES + 1)
    expect(env["rack.input"]).to equal(input)
    expect(env["PATH_INFO"]).to eq(path)
  end

  it "does not limit unrelated paths, invalid route suffixes, or non-POST methods" do
    [ [ "GET", "/student/assignments/12/submission" ],
      [ "PUT", "/student/assignments/12/submission.json" ],
      [ "POST", "/student/assignments/12/answer_draft" ],
      [ "POST", "/student/assignments/12/submissions" ],
      [ "POST", "/student/assignments/12/submission.json.foo" ] ].each do |method, path|
      input = StringIO.new("unrestricted")
      env = { "REQUEST_METHOD" => method, "PATH_INFO" => path,
        "CONTENT_LENGTH" => (described_class::MAX_BYTES + 1).to_s, "rack.input" => input }
      app = ->(request) { [ 200, {}, [ request["rack.input"].read ] ] }

      expect(described_class.new(app).call(env).first).to eq(200), "#{method} #{path}"
    end
  end
end
