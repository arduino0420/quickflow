# Bound request streaming before Rails parses multipart uploads, only on the
# student submission endpoint. This keeps other upload and form routes intact.
class SubmissionRequestBodyLimit
  MAX_BYTES = 32 * 1024 * 1024
  PATH = %r{\A/student/assignments/\d+/submission\z}

  class TooLarge < StandardError; end

  class LimitedInput
    def initialize(input, limit)
      @input = input
      @limit = limit
      @bytes_read = 0
    end

    def read(length = nil, output = nil)
      return output ? output.replace("") : "" if length == 0

      maximum = @limit - @bytes_read + 1
      requested = length ? [ length, maximum ].min : maximum
      chunk = @input.read(requested)
      raise TooLarge if chunk && (@bytes_read += chunk.bytesize) > @limit
      return if chunk.nil?

      output ? output.replace(chunk) : chunk
    end

    def gets(*args)
      separator, requested_limit = case args.length
      when 0 then [ $/, nil ]
      when 1 then args.first.is_a?(Integer) ? [ $/, args.first ] : [ args.first, nil ]
      else args
      end
      remaining = @limit - @bytes_read + 1
      length = requested_limit ? [ requested_limit, remaining ].min : remaining
      line = @input.gets(separator, length)
      raise TooLarge if line && (@bytes_read += line.bytesize) > @limit

      line
    end

    def each(*args)
      return enum_for(__method__, *args) unless block_given?

      yield line while (line = gets(*args))
    end

    def rewind
      @bytes_read = 0
      @input.rewind
    end

    def close
      @input.close
    end
  end

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless env["REQUEST_METHOD"] == "POST" && PATH.match?(env["PATH_INFO"])

    return reject if env["CONTENT_LENGTH"].to_i > MAX_BYTES

    original_input = env["rack.input"]
    env["rack.input"] = LimitedInput.new(original_input, MAX_BYTES)
    @app.call(env)
  rescue TooLarge
    reject
  ensure
    env["rack.input"] = original_input if original_input
  end

  private

  def reject
    [ 413, { "content-type" => "text/plain; charset=utf-8", "cache-control" => "no-store" }, [ "リクエストが上限サイズを超えています。" ] ]
  end
end
