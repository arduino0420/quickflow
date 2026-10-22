class CredentialSession
  def self.issue(record)
    OpenSSL::HMAC.hexdigest("SHA256", key,
      [ record.class.name, record.id, record.password_digest ].to_json)
  end

  def self.valid?(record, proof)
    record && proof.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(issue(record), proof)
  end

  def self.key
    Rails.application.key_generator.generate_key("credential-session-v1", 32)
  end
  private_class_method :key
end
