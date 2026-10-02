class School < ApplicationRecord
  has_many :teachers
  has_many :classrooms

  validates :school_code, presence: true, uniqueness: true,
    format: { with: /\A[a-zA-Z0-9]+\z/ }
end
