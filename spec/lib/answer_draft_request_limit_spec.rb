require "rails_helper"

RSpec.describe AnswerDraftRequestLimit do
  it "rejects oversized bodies on every Rails draft update route variant before reading them" do
    paths = %w[
      /student/assignments/12/answer_draft
      /student/assignments/12/answer_draft/
      /student/assignments/12/answer_draft.json
      /student/assignments/12/answer_draft.xml/
      /student//assignments/12//answer_draft//
      /student/assignments/quiz-12/answer_draft
      /student/assignments/a%2Fb/answer_draft
    ]
    app = ->(_request) { raise "oversized body reached Rails" }

    %w[PUT PATCH].each do |method|
      paths.each do |path|
        route = Rails.application.routes.recognize_path(path, method: method)
        expect(route.slice(:controller, :action)).to eq(controller: "student/answer_drafts", action: "update")
        input = instance_double(StringIO)
        expect(input).not_to receive(:read)
        env = { "REQUEST_METHOD" => method, "PATH_INFO" => path, "CONTENT_TYPE" => "application/json",
          "CONTENT_LENGTH" => (described_class::MAX_BYTES + 1).to_s, "rack.input" => input }

        expect(described_class.new(app).call(env).first).to eq(413), "#{method} #{path}"
        expect(env["PATH_INFO"]).to eq(path)
      end
    end
  end

  it "accepts the exact limit without Content-Length and rejects one byte more" do
    path = "/student/assignments/12/answer_draft.json/"
    prefix = '{"padding":"'
    suffix = '"}'
    body = prefix + ("x" * (described_class::MAX_BYTES - prefix.bytesize - suffix.bytesize)) + suffix
    input = StringIO.new(body)
    env = { "REQUEST_METHOD" => "PATCH", "PATH_INFO" => path, "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => "", "rack.input" => input }
    app = ->(request) { [ 200, {}, [ request["rack.input"].read.bytesize.to_s ] ] }

    status, _headers, response_body = described_class.new(app).call(env)
    expect(status).to eq(200)
    expect(response_body.join).to eq(described_class::MAX_BYTES.to_s)
    expect(env["PATH_INFO"]).to eq(path)

    env["rack.input"] = StringIO.new(body + "x")
    expect(described_class.new(app).call(env).first).to eq(413)
  end

  it "keeps the existing malformed JSON and media type responses on route variants" do
    path = "/student/assignments/12/answer_draft.xml/"
    env = { "REQUEST_METHOD" => "PUT", "PATH_INFO" => path, "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => "4", "rack.input" => StringIO.new("bad!") }
    app = ->(_request) { raise "invalid input reached Rails" }

    expect(described_class.new(app).call(env).first).to eq(400)
    env["CONTENT_TYPE"] = "text/plain"
    expect(described_class.new(app).call(env).first).to eq(415)
  end

  it "does not limit unrelated paths, invalid route suffixes, or other methods" do
    [ [ "GET", "/student/assignments/12/answer_draft" ],
      [ "POST", "/student/assignments/12/answer_draft.json" ],
      [ "PUT", "/student/assignments/12/submission" ],
      [ "PATCH", "/student/assignments/12/answer_drafts" ],
      [ "PATCH", "/student/assignments/12/answer_draft.json.foo" ] ].each do |method, path|
      input = StringIO.new("unrestricted")
      env = { "REQUEST_METHOD" => method, "PATH_INFO" => path, "CONTENT_TYPE" => "text/plain",
        "CONTENT_LENGTH" => (described_class::MAX_BYTES + 1).to_s, "rack.input" => input }
      app = ->(request) { [ 200, {}, [ request["rack.input"].read ] ] }

      expect(described_class.new(app).call(env).first).to eq(200), "#{method} #{path}"
    end
  end
end
