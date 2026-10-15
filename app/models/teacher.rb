class Teacher < ApplicationRecord
  belongs_to :school
  has_many :teacher_classrooms
  has_many :classrooms, through: :teacher_classrooms
  has_many :assignments

  has_secure_password reset_token: false

  validates :user_id, presence: true, uniqueness: true
  validate :user_id_cannot_change, on: :update

  private

  def user_id_cannot_change
    errors.add(:user_id, "は登録後に変更できません") if will_save_change_to_user_id?
  end
end
