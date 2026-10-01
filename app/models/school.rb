class School < ApplicationRecord
  has_many :teachers

  validates :school_code, presence: true, uniqueness: true,
    format: { with: /\A[a-zA-Z0-9]+\z/ }
end
