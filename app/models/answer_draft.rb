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
    reason = page_data_error
    errors.add(:page_data, reason, message: "is invalid or too large") if reason
  end

  def page_data_error
    return :invalid_data unless page_data.is_a?(Array) && page_data.any?
    return :pages_limit if page_data.length > MAX_PAGES
    return :bytes_limit if JSON.generate(page_data).bytesize > MAX_BYTES

    operations = 0
    points = 0
    page_data.each_with_index do |page, index|
      return :invalid_data unless page.is_a?(Hash) && page.keys.sort == %w[operations page_number] && page["page_number"].is_a?(Integer) && page["page_number"] == index + 1
      return :invalid_data unless page["operations"].is_a?(Array)

      operations += page["operations"].length
      return :operations_limit if operations > MAX_OPERATIONS

      ids = {}
      page["operations"].each do |stroke|
        return :invalid_data unless stroke.is_a?(Hash) && stroke.keys.sort == %w[color id points tool width]
        return :invalid_data unless stroke["id"].is_a?(Integer) && stroke["id"].between?(1, 2**53 - 1)
        return :invalid_data if ids.include?(stroke["id"])

        ids[stroke["id"]] = true
        return :invalid_data unless stroke["color"] == "#000000" && %w[pen eraser].include?(stroke["tool"])
        widths = stroke["tool"] == "pen" ? [ 1.2 ] : [ 4, 8, 12, 18 ]
        return :invalid_data unless widths.include?(stroke["width"]) && stroke["points"].is_a?(Array) && stroke["points"].any?

        points += stroke["points"].length
        return :points_limit if points > MAX_POINTS

        valid_points = stroke["points"].all? do |point|
          point.is_a?(Array) && point.length == 2 && point.all? do |value|
            value.is_a?(Numeric) && value.finite? && value.abs <= 1_000_000
          end
        end
        return :invalid_data unless valid_points
      end
    end
    nil
  rescue JSON::GeneratorError
    :invalid_data
  end
end
