require "rails_helper"

RSpec.describe "Sensitive parameter filtering" do
  it "redacts identifying inputs and answer text while retaining safe IDs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    input = { school_code: "PRIVATE SCHOOL", grade: "PRIVATE GRADE", class_number: "PRIVATE CLASS",
      attendance_number: "PRIVATE NUMBER", user_id: "PRIVATE USER", password: "PRIVATE PASSWORD",
      admin_password: "PRIVATE ADMIN PASSWORD", student_answer: "PRIVATE ANSWER", page_data: "PRIVATE INK",
      draft_data: "PRIVATE DRAFT", submission_token: "PRIVATE TOKEN", material_file: "PRIVATE FILENAME",
      answer_file: "PRIVATE ANSWER FILENAME", assignment_id: "safe-id" }

    result = filter.filter(input)

    expect(result.except(:assignment_id).values).to all(eq("[FILTERED]"))
    expect(result[:assignment_id]).to eq("safe-id")
  end
end
