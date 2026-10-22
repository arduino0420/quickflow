require Rails.root.join("lib/submission_request_body_limit")
Rails.application.config.middleware.insert_before Rails::Rack::Logger, SubmissionRequestBodyLimit
