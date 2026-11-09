# ISOLATED REPRODUCTION ONLY. Mount read-only; never ship in a release image.
require "ostruct"
raise "Local-only guard missing" unless ENV["QF_LOCAL_ONLY"] == "1" && %w[dev check].include?(ENV["QF_LOCAL_MODE"]) && ENV["PGHOST"] == "db"
expected_env = ENV["QF_LOCAL_MODE"] == "dev" ? "development" : "production"
raise "Wrong Rails mode" unless Rails.env == expected_env
raise "Real master key forbidden" if ENV["RAILS_MASTER_KEY"].present?
raise "Real API credentials forbidden" if ENV.keys.any? { |k| k.match?(/OPENAI.*(?:KEY|TOKEN)/) && ENV[k].to_s != "" }

module QfLocal
  MODEL = "synthetic-local-no-external-ai"
  def self.audit(kind)
    File.open("/rails/tmp/local-ai.jsonl", "a") do |f|
      f.puts(JSON.generate(event: kind, pid: Process.pid, time: Time.now.utc.iso8601))
    end
  end
  class Client
    def files = Files.new
    def responses = Responses.new
  end
  class Files
    def create(**options)
      raise "Synthetic PDF expected" unless options[:purpose] == "user_data"
      QfLocal.audit("file_create")
      OpenStruct.new(id: "file-synthetic-#{SecureRandom.hex(8)}")
    end
    def delete(id)
      raise "Not a synthetic file" unless id.start_with?("file-synthetic-")
      QfLocal.audit("file_delete")
      OpenStruct.new(deleted: true)
    end
  end
  class Responses
    def create(**options)
      if options.dig(:text, :format, :name) == "generated_questions"
        kind = "question_generation"
        result = { questions: [ { question_label: "1", question_text: "1+1", correct_answer: "2", grading_rule: "Answer must equal 2", requires_work: false } ] }
      elsif options[:input].is_a?(String)
        kind = "answer_grading"
        data = JSON.parse(options[:input]).fetch("problems")
        result = { results: data.map { |problem| { question_id: problem.fetch("question_id"), ai_judgment: "correct", error_point: nil, feedback: nil, review_reason: nil } } }
      else
        kind = "answer_reading"
        result = { problems: [ { question_label: "1", question_text: "1+1", student_answer: "2", reading_status: "readable", reading_reason: "Synthetic fixed response; no image recognition performed" } ] }
      end
      QfLocal.audit(kind)
      OpenStruct.new(id: "synthetic-response", status: "completed", output: [], error: nil,
        incomplete_details: nil, output_text: JSON.generate(result), model: MODEL, usage: nil)
    end
  end
  module ClientOverride
    def build(api_key: nil)
      raise "API key passed to reproduction" if api_key.present?
      QfLocal::Client.new
    end
  end
  module ForbidRealOpenAI
    def new(*) = raise("Real OpenAI client forbidden in isolated reproduction")
  end
end
module QfLocal
  class SyntheticHeader
    def initialize(app) = @app = app
    def call(env)
      status, headers, body = @app.call(env)
      [ status, headers.merge("X-QuickFlow-Local-AI" => "synthetic"), body ]
    end
  end
end
Rails.application.config.middleware.use QfLocal::SyntheticHeader
Rails.application.config.to_prepare do
  AiClient.singleton_class.prepend(QfLocal::ClientOverride) unless AiClient.singleton_class < QfLocal::ClientOverride
  OpenAI::Client.singleton_class.prepend(QfLocal::ForbidRealOpenAI) unless OpenAI::Client.singleton_class < QfLocal::ForbidRealOpenAI
end
