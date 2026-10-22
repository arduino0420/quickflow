class Student < ApplicationRecord
  belongs_to :classroom
  has_many :submissions

  has_secure_password reset_token: false

  validate :new_password_policy, if: -> { persisted? && will_save_change_to_password_digest? }

  validates :attendance_number, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 40 },
    uniqueness: { scope: :classroom_id }

  private

  def new_password_policy
    message = PasswordPolicy.message_for(password, role: :student)
    errors.add(:password, message) if message
  end
end
