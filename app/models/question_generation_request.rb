class QuestionGenerationRequest < ApplicationRecord
  STATES = %w[pending running succeeded failed].freeze
  FAILURE_CODES = %w[generation_failed enqueue_failed].freeze

  belongs_to :assignment
  attr_readonly :assignment_id, :material_blob_id, :model, :prompt_version
  validates :material_blob_id, :model, :prompt_version, presence: true
  validates :state, inclusion: { in: STATES }
  validates :failure_code, inclusion: { in: FAILURE_CODES }, allow_nil: true
  validates :material_blob_id, uniqueness: { scope: [ :assignment_id, :model, :prompt_version ] }

  # Only the explicit new-distribution lifecycle creates intent. Reads never do.
  def self.select_for_distribution!(assignment, model: AiClient.model(:question_generation))
    request = find_or_create_by!(assignment: assignment, material_blob_id: assignment.material_file.blob.id,
      model: model, prompt_version: QuestionGenerator::PROMPT_VERSION)
    assignment.update!(current_question_generation_request: request)
    request
  end

  def selected_input?(owner)
    assignment_id == owner.id && owner.current_question_generation_request_id == id &&
      owner.material_file.blob&.id == material_blob_id && prompt_version == QuestionGenerator::PROMPT_VERSION
  end

  def with_selected_lock
    assignment.with_lock("FOR NO KEY UPDATE") do
      reload
      yield assignment if selected_input?(assignment)
    end
  end

  def claim!
    token = nil
    with_selected_lock do
      if state == "pending"
        token = SecureRandom.uuid
        update!(state: "running", claim_token: token, started_at: Time.current)
      end
    end
    token
  end

  def owned?(owner, token)
    selected_input?(owner) && state == "running" && token.present? && claim_token == token
  end

  def fail!(token:, code: "generation_failed")
    with_selected_lock do |owner|
      update!(state: "failed", failure_code: code, finished_at: Time.current) if owned?(owner, token)
    end
  end

  def enqueue_failed!
    with_selected_lock do
      update!(state: "failed", failure_code: "enqueue_failed", finished_at: Time.current) if state == "pending"
    end
  end
end
