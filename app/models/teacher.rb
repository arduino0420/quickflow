class Teacher < ApplicationRecord
  belongs_to :school
  has_many :teacher_classrooms
  has_many :classrooms, through: :teacher_classrooms
  has_many :assignments

  has_secure_password reset_token: false

  validate :new_password_policy, if: -> { persisted? && will_save_change_to_password_digest? }

  validates :user_id, presence: true, uniqueness: true
  validate :user_id_cannot_change, on: :update

  private

  def new_password_policy
    message = PasswordPolicy.message_for(password, role: :teacher)
    errors.add(:password, message) if message
  end

  def user_id_cannot_change
    errors.add(:user_id, "は登録後に変更できません") if will_save_change_to_user_id?
  end
end
