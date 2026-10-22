module Demo
  # This profile accepts direct TLS only. No forwarded header is trusted.
  class TransportBoundary
    def initialize(app)
      @app = app
      target = Profile.settings
      @host = target.fetch("allowed_host")
      @authority = "#{@host}:#{target.fetch('https_port')}"
    end

    def call(env)
      forwarded = env.keys.any? { |key| key.start_with?("HTTP_X_FORWARDED_") || %w[HTTP_FORWARDED HTTP_X_REAL_IP HTTP_X_URL_SCHEME HTTP_FRONT_END_HTTPS].include?(key) }
      unless !forwarded && env["rack.url_scheme"] == "https" && [ @host, @authority ].include?(env["HTTP_HOST"])
        return [ 400, { "content-type" => "text/plain; charset=utf-8", "cache-control" => "private, no-store" }, [ "デモ接続を確認できません。" ] ]
      end
      @app.call(env)
    end
  end
end
