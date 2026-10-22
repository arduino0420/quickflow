module Demo
  class Guest
    class Unavailable < StandardError; end
    ROLES = { "admin" => Admin, "teacher" => Teacher, "student" => Student }.freeze
    READS = {
      "admin" => { "admin/dashboard" => %w[show], "admin/teachers" => %w[index], "admin/students" => %w[index] },
      "teacher" => { "assignments" => %w[index show export], "submissions" => %w[show answer] },
      "student" => { "student/assignments" => %w[index show result material answer] }
    }.freeze
    TTL = 15.minutes

    def self.configured?
      ENV["QUICKFLOW_GUEST_LOGIN"] == "true"
    end

    def self.enabled?
      configured? && Rails.env.test?
    end

    def self.verify!
      raise Unavailable unless enabled?
      Seed.new.verify_guest!
    rescue Seed::UnsafeTarget, JSON::ParserError, KeyError, IOError, SystemCallError, ActiveRecord::ActiveRecordError => error
      Rails.logger.warn("Guest demo unavailable: #{error.class}")
      raise Unavailable
    end

    def self.record(role)
      model = ROLES[role]
      raise Unavailable unless model
      school = School.find_by!(school_code: "DEMO1")
      case role
      when "admin", "teacher"
        model.find_by!(school: school, user_id: "demo-#{role}-1")
      when "student"
        Student.joins(:classroom).find_by!(classrooms: { school_id: school.id, grade: 1, class_number: 1 }, attendance_number: 1)
      end
    end

    def self.key(nonce)
      OpenSSL::HMAC.hexdigest("SHA256", Rails.application.key_generator.generate_key("guest-session-v1", 32), nonce)
    end

    def self.revoke(session)
      nonce = session[:guest_nonce]
      AuthenticationAttemptBucket.where(key_digest: key(nonce)).delete_all if nonce.is_a?(String)
    end

    def self.valid?(session)
      role = session[:guest_role]
      return false unless ROLES.key?(role) && session[:guest_nonce].is_a?(String)
      account = record(role)
      ids = ROLES.keys.select { |name| session[:"#{name}_id"].present? }
      return false unless ids == [ role ] && session[:"#{role}_id"] == account.id &&
        CredentialSession.valid?(account, session[:credential_proof])
      AuthenticationAttemptBucket.where(key_digest: key(session[:guest_nonce]))
        .where("expires_at > ? AND expires_at <= ?", Time.current, Time.current + TTL).exists?
    end
  end
end
