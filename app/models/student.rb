class Student < ApplicationRecord
  belongs_to :classroom

  has_secure_password reset_token: false

  validates :attendance_number, presence: true,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 40 },
    uniqueness: { scope: :classroom_id }
end
