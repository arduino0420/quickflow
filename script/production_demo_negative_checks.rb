# Rails runner diagnostic for the freshly created local smoke cluster only.
# Administrative access belongs to this verifier, never to the demo web process.
require "pg"
context = JSON.parse(File.read(ARGV.fetch(0)))
target = context.fetch("target")
raise "Wrong verification identity" unless Demo::Profile.identity? && Demo::Profile.settings == target
admin = PG.connect(host: target.fetch("host"), port: target.fetch("port"), dbname: target.fetch("database"), user: context.fetch("admin_name"))
actual = admin.exec("SELECT current_setting('data_directory'),(SELECT system_identifier::text FROM pg_control_system())").values.first
raise "Not the task-local cluster" unless actual == target.values_at("data_directory", "system_identifier")
runtime = admin.quote_ident(target.fetch("runtime_role"))
database = admin.quote_ident(target.fetch("database"))
verifier = -> { Demo::TargetVerifier.new.verify_runtime! }
refusals = 0
expect_refusal = lambda do |label|
  writes = []
  subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
    sql = args.last.fetch(:sql)
    writes << sql if sql.match?(/\A\s*(?:INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|TRUNCATE|GRANT|REVOKE)\b/i)
  end
  begin
    verifier.call
    raise "Unsafe case accepted: #{label}"
  rescue Demo::Profile::Unsafe
    raise "Verifier wrote SQL in #{label}" unless writes.empty?
    refusals += 1
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
begin
  verifier.call
  [
    [ "UPDATE on ledger", "GRANT UPDATE ON question_generation_requests TO #{runtime}", "REVOKE UPDATE ON question_generation_requests FROM #{runtime}" ],
    [ "ledger sequence access", "GRANT USAGE ON SEQUENCE question_generation_requests_id_seq TO #{runtime}", "REVOKE USAGE ON SEQUENCE question_generation_requests_id_seq FROM #{runtime}" ],
    [ "UPDATE on business table", "GRANT UPDATE ON schools TO #{runtime}", "REVOKE UPDATE ON schools FROM #{runtime}" ],
    [ "column INSERT", "GRANT INSERT (school_code) ON schools TO #{runtime}", "REVOKE INSERT (school_code) ON schools FROM #{runtime}" ],
    [ "grant option", "GRANT SELECT ON schools TO #{runtime} WITH GRANT OPTION", "REVOKE GRANT OPTION FOR SELECT ON schools FROM #{runtime}" ],
    [ "column grant option", "GRANT SELECT (school_code) ON schools TO #{runtime} WITH GRANT OPTION", "REVOKE SELECT (school_code) ON schools FROM #{runtime}" ],
    [ "database grant option", "GRANT CONNECT ON DATABASE #{database} TO #{runtime} WITH GRANT OPTION", "REVOKE GRANT OPTION FOR CONNECT ON DATABASE #{database} FROM #{runtime}" ],
    [ "schema grant option", "GRANT USAGE ON SCHEMA public TO #{runtime} WITH GRANT OPTION", "REVOKE GRANT OPTION FOR USAGE ON SCHEMA public FROM #{runtime}" ],
    [ "TEMP", "GRANT TEMP ON DATABASE #{database} TO #{runtime}", "REVOKE TEMP ON DATABASE #{database} FROM #{runtime}" ],
    [ "other DB CONNECT", "GRANT CONNECT ON DATABASE postgres TO #{runtime}", "REVOKE CONNECT ON DATABASE postgres FROM #{runtime}" ],
    [ "other DB TEMP", "GRANT TEMP ON DATABASE postgres TO #{runtime}", "REVOKE TEMP ON DATABASE postgres FROM #{runtime}" ],
    [ "schema CREATE", "GRANT CREATE ON SCHEMA public TO #{runtime}", "REVOKE CREATE ON SCHEMA public FROM #{runtime}" ],
    [ "role CREATEDB", "ALTER ROLE #{runtime} CREATEDB", "ALTER ROLE #{runtime} NOCREATEDB" ],
    [ "role membership", "GRANT pg_read_all_stats TO #{runtime}", "REVOKE pg_read_all_stats FROM #{runtime}" ],
    [ "unknown schema", "CREATE SCHEMA demo_verification_probe", "DROP SCHEMA demo_verification_probe" ],
    [ "unknown sequence", "CREATE SEQUENCE demo_verification_probe", "DROP SEQUENCE demo_verification_probe" ]
  ].each do |label, change, restore|
    admin.exec(change)
    begin
      expect_refusal.call(label)
    ensure
      admin.exec(restore)
    end
    verifier.call
  end
  original_marker = "quickflow-production-demo:#{target.fetch('isolation_id')}"
  admin.exec("COMMENT ON DATABASE #{database} IS 'wrong-verification-marker'")
  begin
    expect_refusal.call("database marker")
  ensure
    admin.exec("COMMENT ON DATABASE #{database} IS #{admin.escape_literal(original_marker)}")
  end
  root = Pathname.new(target.fetch("storage_root"))
  [ [ root.join(".demo-isolation"), "wrong" ], [ root.join(".seed-manifest.json"), "{}" ] ].each do |path, wrong|
    original = path.binread
    path.binwrite(wrong)
    begin
      expect_refusal.call(path.basename.to_s)
    ensure
      path.binwrite(original)
    end
  end
  manifest_path = root.join(".seed-manifest.json")
  original_manifest = manifest_path.binread
  old_manifest = JSON.parse(original_manifest)
  old_manifest.fetch("tables").delete("question_generation_requests")
  manifest_path.write(JSON.generate(old_manifest))
  begin
    expect_refusal.call("old manifest missing generation ledger")
    raise "Manifest was automatically repaired" unless JSON.parse(manifest_path.read) == old_manifest
  ensure
    manifest_path.binwrite(original_manifest)
  end
  probe = root.join("forbidden-symlink")
  probe.make_symlink(root.join(".demo-isolation"))
  begin
    expect_refusal.call("storage symlink")
  ensure
    probe.unlink
  end
  original_env = ENV.to_h
  [ [ "QUICKFLOW_DEMO_SESSION_SECRET", nil ], [ "SOLID_QUEUE_IN_PUMA", "false" ],
    [ "PRIMARY_DATABASE_URL", context.fetch("urls").fetch("runtime") ],
    [ "QUEUE_DATABASE_URL", "postgresql://127.0.0.1:1/must-never-connect" ],
    [ "QUICKFLOW_DEMO_DATABASE_URL", context.fetch("urls").fetch("provision") ] ].each do |key, wrong|
    wrong.nil? ? ENV.delete(key) : ENV[key] = wrong
    begin
      expect_refusal.call(key)
    ensure
      ENV.replace(original_env)
    end
  end
  sentinel_name = "quickflow_sentinel_#{SecureRandom.hex(8)}"
  # Refuse reuse: this creates one new synthetic database, never resets a database.
  admin.exec("CREATE DATABASE #{admin.quote_ident(sentinel_name)}")
  admin.exec("REVOKE ALL ON DATABASE #{admin.quote_ident(sentinel_name)} FROM PUBLIC")
  admin.exec("GRANT CONNECT ON DATABASE #{admin.quote_ident(sentinel_name)} TO #{runtime}")
  sentinel = PG.connect(host: target.fetch("host"), port: target.fetch("port"), dbname: sentinel_name, user: context.fetch("admin_name"))
  sentinel.exec("CREATE TABLE synthetic_sentinel(value text NOT NULL)")
  sentinel.exec("INSERT INTO synthetic_sentinel VALUES ('synthetic-only-do-not-change')")
  expected = sentinel.exec("TABLE synthetic_sentinel").values
  original_config = ApplicationRecord.connection_db_config.configuration_hash
  begin
    ApplicationRecord.establish_connection(original_config.merge(database: sentinel_name))
    expect_refusal.call("actual connection to synthetic sentinel database")
    raise "Sentinel changed" unless sentinel.exec("TABLE synthetic_sentinel").values == expected
  ensure
    ApplicationRecord.establish_connection(original_config)
    sentinel.finish
    admin.exec("REVOKE CONNECT ON DATABASE #{admin.quote_ident(sentinel_name)} FROM #{runtime}")
  end
  verifier.call
  puts "#{refusals} fail-closed cases passed with zero verifier SQL writes; synthetic sentinel and complete business/file manifest unchanged"
ensure
  admin.finish
end
