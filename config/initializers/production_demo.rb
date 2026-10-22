if Demo::Profile.identity?
  ActiveJob::Base.before_enqueue { raise Demo::Profile::Unsafe, "Jobs forbidden in demo identity" }
  ActiveJob::Base.before_perform { raise Demo::Profile::Unsafe, "Job execution forbidden in demo identity" }
  Rails.application.config.after_initialize do
    if Demo::Profile.provisioning?
      Demo::TargetVerifier.new.verify_endpoint!(provisioning: true)
    else
      Demo::TargetVerifier.new.verify_runtime!
    end
  end
end
