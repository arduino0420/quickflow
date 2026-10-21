class Admin < ApplicationRecord
  belongs_to :school

  has_secure_password reset_token: false

  validate :new_password_policy, if: -> { persisted? && will_save_change_to_password_digest? }

  validates :user_id, presence: true, uniqueness: true

  private

  def new_password_policy
    message = PasswordPolicy.message_for(password, role: :admin)
    errors.add(:password, message) if message
  end
end
