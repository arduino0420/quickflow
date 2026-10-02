class Teacher < ApplicationRecord
  belongs_to :school
  has_many :classrooms

  has_secure_password reset_token: false

  validates :user_id, presence: true, uniqueness: true
end
