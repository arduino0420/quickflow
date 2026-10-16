class AnswerDraft < ApplicationRecord
  MAX_BYTES = 4.megabytes
  MAX_PAGES = 200
  MAX_OPERATIONS = 10_000
  MAX_POINTS = 100_000

  belongs_to :student
  belongs_to :assignment
  validates :student_id, uniqueness: { scope: :assignment_id }
  validates :material_fingerprint, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :format_version, inclusion: { in: [ 1 ] }
  validate :valid_page_data

  private

  def valid_page_data
    errors.add(:page_data, "is invalid or too large") unless valid_pages?
  end

  def valid_pages?
    return false unless page_data.is_a?(Array) && page_data.length.between?(1, MAX_PAGES)
    return false if JSON.generate(page_data).bytesize > MAX_BYTES

    operations = 0
    points = 0
    page_data.each_with_index.all? do |page, index|
      next false unless page.is_a?(Hash) && page.keys.sort == %w[operations page_number] && page["page_number"].is_a?(Integer) && page["page_number"] == index + 1
      next false unless page["operations"].is_a?(Array)

      operations += page["operations"].length
      next false if operations > MAX_OPERATIONS

      ids = {}
      page["operations"].all? do |stroke|
        next false unless stroke.is_a?(Hash) && stroke.keys.sort == %w[color id points tool width]
        next false unless stroke["id"].is_a?(Integer) && stroke["id"].between?(1, 2**53 - 1)
        next false if ids.include?(stroke["id"])

        ids[stroke["id"]] = true
        next false unless stroke["color"] == "#000000" && %w[pen eraser].include?(stroke["tool"])
        widths = stroke["tool"] == "pen" ? [ 1.2 ] : [ 4, 8, 12 ]
        next false unless widths.include?(stroke["width"]) && stroke["points"].is_a?(Array) && stroke["points"].any?

        points += stroke["points"].length
        next false if points > MAX_POINTS

        stroke["points"].all? do |point|
          point.is_a?(Array) && point.length == 2 && point.all? do |value|
            value.is_a?(Numeric) && value.finite? && value.abs <= 1_000_000
          end
        end
      end
    end
  rescue JSON::GeneratorError
    false
  end
end
