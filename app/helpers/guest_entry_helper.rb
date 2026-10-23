module GuestEntryHelper
  def configured_guest_entry_url
    return if Demo::Profile.identity?

    value = ENV["QUICKFLOW_GUEST_ENTRY_URL"].to_s
    return if value.empty?

    uri = URI.parse(value)
    allowed_host = /\Aqfd-[0-9a-f]{16}\.#{Regexp.escape(request.host)}\z/
    return unless uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.host&.match?(allowed_host)
    return unless uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && [ "", "/" ].include?(uri.path)

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end
end
