# Ephemeral authentication limits, shared across processes and retained on restart.
# Keys are HMACs; never store login identifiers, source addresses or passwords.
class AuthenticationAttemptBucket < ApplicationRecord
  self.primary_key = :key_digest
end
