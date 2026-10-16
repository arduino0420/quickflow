require Rails.root.join("lib/answer_draft_request_limit")
Rails.application.config.middleware.insert_before Rails::Rack::Logger, AnswerDraftRequestLimit
