# Run only through the isolated production verification harness.
raise "Runtime demo required" unless Demo::Profile.identity? && !Demo::Profile.provisioning?
Demo::TargetVerifier.new.verify_runtime!
connection = ApplicationRecord.connection
tables = Demo::Seed::TABLE_MODELS.map(&:table_name) + Demo::TargetVerifier::METADATA
denied = 0
tables.each do |table|
  next if table == AuthenticationAttemptBucket.table_name
  sql = "DELETE FROM #{connection.quote_table_name(table)} WHERE false"
  begin
    ApplicationRecord.transaction(requires_new: true) { connection.execute(sql); raise ActiveRecord::Rollback }
    raise "Runtime business DELETE privilege: #{table}"
  rescue ActiveRecord::StatementInvalid => error
    raise unless error.cause.is_a?(PG::InsufficientPrivilege)
    denied += 1
  end
end
[ "CREATE TABLE public.demo_forbidden_probe(id integer)", "CREATE TEMP TABLE demo_forbidden_probe(id integer)",
  "CREATE SCHEMA demo_forbidden_probe", "TRUNCATE authentication_attempt_buckets" ].each do |sql|
  begin
    ApplicationRecord.transaction(requires_new: true) { connection.execute(sql); raise ActiveRecord::Rollback }
    raise "Runtime DDL/TRUNCATE allowed"
  rescue ActiveRecord::StatementInvalid => error
    raise unless error.cause.is_a?(PG::InsufficientPrivilege)
    denied += 1
  end
end
ApplicationRecord.transaction do
  probe = AuthenticationAttemptBucket.create!(key_digest: "f" * 64, attempts: 0, expires_at: Time.current + 60)
  probe.update!(attempts: 1)
  probe.destroy!
  raise ActiveRecord::Rollback
end
begin
  AiClient.build(api_key: "synthetic-never-used")
  raise "AI allowed"
rescue Demo::Guest::Unavailable
  nil
end
job = Class.new(ActiveJob::Base) { def perform = raise("Job body executed") }
[ -> { job.perform_later }, -> { job.perform_now } ].each do |action|
  begin
    action.call
    raise "Job allowed"
  rescue Demo::Profile::Unsafe
    nil
  end
end
service = ActiveStorage::Blob.services.fetch("production_demo")
%i[upload delete delete_prefixed compose update_metadata].each do |operation|
  begin
    service.public_send(operation, "synthetic-never-written")
    raise "Storage mutation allowed"
  rescue Demo::Profile::Unsafe
    nil
  end
end
raise "Cache persists" unless Rails.cache.is_a?(ActiveSupport::Cache::NullStore)
raise "Secondary configuration" unless ApplicationRecord.configurations.configs_for(env_name: "production").map(&:name) == [ "primary" ]
Demo::TargetVerifier.new.verify_runtime!
target = Demo::Profile.settings
request = ActionDispatch::Request.new(Rails.application.env_config.merge("rack.url_scheme" => "https", "HTTP_HOST" => target.fetch("allowed_host")))
jar = ActionDispatch::Cookies::CookieJar.build(request, {})
session_key = Rails.application.config.session_options.fetch(:key)
teacher = Demo::Guest.record("teacher")
normal_session = { "teacher_id" => teacher.id, "credential_proof" => CredentialSession.issue(teacher) }
jar.encrypted[session_key] = { value: normal_session }
raise "Normal-cookie fixture not valid" unless jar.encrypted[session_key] == normal_session
control = Rails.root.join("tmp/production-demo-control-#{target.fetch('isolation_id')}")
File.open(control.join("old-normal-cookie"), File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
  file.write("#{session_key}=#{Rack::Utils.escape(jar[session_key])}")
end
puts "Runtime effective privileges: #{denied} business/DDL denials; auth CRUD, no-AI, no-enqueue/execution, no-Disk-write, null cache, primary-only and unchanged manifest passed"
