# Run before request logging / Rails parameter parsing. Never log malformed ink.
class AnswerDraftRequestLimit
  MAX_BYTES = 4 * 1024 * 1024 + 16 * 1024

  def initialize(app)
    @app = app
  end

  def call(env)
    if %w[PUT PATCH].include?(env["REQUEST_METHOD"]) && env["PATH_INFO"].match?(%r{\A/student/assignments/[^/]+/answer_draft(?:\.json)?\z})
      return reject(415) unless env["CONTENT_TYPE"].to_s.split(";").first == "application/json"
      return reject(413) if env["CONTENT_LENGTH"].to_i > MAX_BYTES

      body = env["rack.input"].read(MAX_BYTES + 1)
      return reject(413) if body.bytesize > MAX_BYTES

      begin
        return reject(400) unless JSON.parse(body).is_a?(Hash)
      rescue JSON::ParserError
        return reject(400)
      end
      env["rack.input"] = StringIO.new(body)
    end
    @app.call(env)
  end

  private

  def reject(status)
    [ status, { "content-type" => "application/json", "cache-control" => "private, no-store" }, [ '{"error":"invalid_request"}' ] ]
  end
end
