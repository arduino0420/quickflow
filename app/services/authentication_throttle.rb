class AuthenticationThrottle
  class Limited < StandardError
    attr_reader :retry_after

    def initialize(retry_after)
      @retry_after = retry_after
      super("Authentication temporarily limited")
    end
  end
  class Unavailable < StandardError; end

  LIMITS = {
    login: [ [ 10, 10.minutes ], [ 50, 15.minutes ] ],
    reauthentication: [ [ 5, 5.minutes ], [ 10, 15.minutes ] ]
  }.freeze

  # Built once, with the same configured work factor as new account passwords.
  DUMMY_PASSWORD = BCrypt::Password.create(SecureRandom.hex(32),
    cost: ActiveModel::SecurePassword.min_cost ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost)

  def self.identifier(value)
    value if value.is_a?(String) && value.valid_encoding? && !value.include?("\0")
  end

  def initialize(role:, identity:, source:, record:, purpose: :login)
    @record = record
    limits = LIMITS.fetch(purpose)
    generation = record ? CredentialSession.issue(record) : "unknown"
    account = [ purpose, role, identity, generation ]
    @buckets = [ [ digest([ account, source ]), *limits[0] ], [ digest(account), *limits[1] ] ]
      .sort_by(&:first)
  end

  def authenticate(password)
    reservations = reserve!
    # Keep existing password semantics, including whitespace; strength policy is
    # a separate, unapproved stage. Only guard bcrypt's input type/byte limit.
    valid_password = self.class.identifier(password).is_a?(String) && password.bytesize <= 72
    authenticated = if @record && valid_password
      @record.authenticate(password)
    else
      DUMMY_PASSWORD.is_password?(valid_password ? password : "")
      false
    end
    reset!(reservations) if authenticated
    !!authenticated
  rescue ActiveRecord::ActiveRecordError, PG::Error => error
    Rails.logger.error("Authentication throttle storage unavailable: #{error.class}")
    raise Unavailable, "Authentication storage unavailable"
  end

  private

  def digest(value)
    key = Rails.application.key_generator.generate_key("authentication-throttle-v1", 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, JSON.generate(value))
  end

  def reserve!
    # Insert/lock in a stable order, including first-use races. Never hold these
    # locks during bcrypt. Rejected requests do not move either expiry forward.
    result = AuthenticationAttemptBucket.transaction(requires_new: true) do
      now = Time.current
      @buckets.each do |key, _limit, duration|
        AuthenticationAttemptBucket.insert_all([ { key_digest: key, attempts: 0, expires_at: now + duration } ])
      end
      rows = AuthenticationAttemptBucket.where(key_digest: @buckets.map(&:first)).order(:key_digest).lock.to_a
      # Cleanup may remove an already-expired row between insertion and locking.
      # Fail closed rather than authenticate with a missing bucket.
      raise Unavailable, "Authentication counter unavailable" unless rows.length == @buckets.length

      now = Time.current
      waits = rows.zip(@buckets).filter_map do |row, (_key, limit, _duration)|
        (row.expires_at - now).ceil if row.expires_at > now && row.attempts >= limit
      end
      if waits.any?
        { retry_after: waits.max }
      else
        rows.zip(@buckets).to_h do |row, (_key, _limit, duration)|
          expired = row.expires_at <= now
          row.update_columns(attempts: (expired ? 0 : row.attempts) + 1,
            expires_at: expired ? now + duration : row.expires_at)
          [ row.key_digest, row.expires_at ]
        end
      end
    end
    raise Limited, result[:retry_after] if result.key?(:retry_after)

    result
  end

  def reset!(reservations)
    # A delayed success must not delete a newer window's attempts.
    AuthenticationAttemptBucket.transaction(requires_new: true) do
      reservations.each do |key, expiry|
        AuthenticationAttemptBucket.where(key_digest: key, expires_at: expiry).delete_all
      end
    end
  end
end
