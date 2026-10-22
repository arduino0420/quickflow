#!/usr/bin/env ruby
# Creates only a fresh task-local cluster. Never points at an existing DB.
require "fileutils"
require "tmpdir"
require "etc"
require "socket"
require "securerandom"
require "open3"
require "json"
require "pg"
require "openssl"
require "uri"
require "net/http"
require "nokogiri"
require "timeout"
require "digest"

ROOT = File.expand_path("..", __dir__)
Dir.chdir(ROOT)
RESUME = ENV["QUICKFLOW_DEMO_SMOKE_RESUME"]
ID = RESUME ? File.basename(RESUME).delete_prefix("production-demo-control-") : SecureRandom.hex(16)
raise "Invalid resume ID" unless ID.match?(/\A[0-9a-f]{32}\z/)
SUFFIX = ID[0, 16]
CONTROL = File.join(ROOT, "tmp", "production-demo-control-#{ID}")
CLUSTER = File.join(ROOT, "tmp", "production-demo-pg-#{ID}")
STORAGE = File.join(ROOT, "tmp", "production-demo-#{ID}")
if RESUME
  raise "Only the initialized, never-started task cluster may resume" unless RESUME == CONTROL &&
    Dir.children(CONTROL).sort == %w[initdb.log pg-start.log] && File.read(File.join(CLUSTER, "PG_VERSION")).strip == "18" && !File.exist?(File.join(CLUSTER, "postmaster.pid"))
else
  [ CONTROL, CLUSTER, STORAGE ].each { |path| Dir.mkdir(path, 0o700) }
end
File.write(File.join(ROOT, "tmp", "production-demo-latest-control"), CONTROL)
raise "Storage marker differs" if RESUME && File.read(File.join(STORAGE, ".demo-isolation")) != ID
File.write(File.join(STORAGE, ".demo-isolation"), ID) unless RESUME
def unused_port
  server = TCPServer.new("127.0.0.1", 0)
  server.addr[1]
ensure
  server&.close
end
DB_PORT = unused_port
HTTPS_PORT = unused_port
ROLE_PASSWORDS = { "provision" => SecureRandom.hex(32), "runtime" => SecureRandom.hex(32) }.freeze
SESSION_SECRET = SecureRandom.hex(64)
ALL_SECRETS = (ROLE_PASSWORDS.values + [ SESSION_SECRET ]).freeze

def scrub(value)
  ALL_SECRETS.reduce(value.to_s) { |text, secret| text.gsub(secret, "[REDACTED]") }
end

def command!(name, env, *args)
  output, error, status = Open3.capture3(env, *args, chdir: ROOT, unsetenv_others: true)
  File.write(File.join(CONTROL, "#{name}.log"), scrub(output + error))
  raise "#{name} failed; inspect its redacted log" unless status.success?
  output
end

BASE_ENV = { "PATH" => ENV.fetch("PATH"), "HOME" => ENV.fetch("HOME"), "LC_ALL" => "C" }.freeze
command!("initdb", BASE_ENV, "initdb", "-D", CLUSTER, "-A", "trust", "--no-locale", "-E", "UTF8") unless RESUME
SOCKET_DIR = Dir.mktmpdir("qfd-socket-", "/tmp")
File.write(File.join(CONTROL, "socket-path"), SOCKET_DIR)
admin_name = Etc.getpwuid.name
File.write(File.join(CLUSTER, "pg_hba.conf"), "local all all trust\nhost all \"#{admin_name}\" 127.0.0.1/32 trust\nhost all all 127.0.0.1/32 scram-sha-256\n")
command!("pg-start", BASE_ENV, "pg_ctl", "-D", CLUSTER, "-l", File.join(CLUSTER, "server.log"), "-o", "-h 127.0.0.1 -p #{DB_PORT} -k #{SOCKET_DIR}", "-w", "start")
admin = PG.connect(host: "127.0.0.1", port: DB_PORT, dbname: "postgres", user: admin_name)
actual = admin.exec("SELECT current_database(),host(inet_server_addr()),inet_server_port()::text,current_setting('data_directory'),(SELECT system_identifier::text FROM pg_control_system())").values.first
control_info = command!("pg-control", BASE_ENV, "pg_controldata", CLUSTER)
system_id = control_info[/^Database system identifier:\s*(\d+)/, 1]
raise "New cluster endpoint/identity mismatch" unless actual == [ "postgres", "127.0.0.1", DB_PORT.to_s, CLUSTER, system_id ] && File.stat(CLUSTER).uid == Process.uid
pid = Integer(File.readlines(File.join(CLUSTER, "postmaster.pid")).first)
owner, = Open3.capture2("ps", "-p", pid.to_s, "-o", "uid=")
raise "New process owner mismatch" unless owner.strip == Process.uid.to_s
# Password statements are never printed/logged, including on errors.
admin.exec("SET log_min_error_statement = 'panic'")
roles = { "provision" => "qfd_provision_#{SUFFIX}", "runtime" => "qfd_runtime_#{SUFFIX}" }
roles.each do |kind, role|
  admin.exec("CREATE ROLE #{PG::Connection.quote_ident(role)} LOGIN NOSUPERUSER #{kind == "provision" ? "INHERIT" : "NOINHERIT"} NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS PASSWORD #{admin.escape_literal(ROLE_PASSWORDS.fetch(kind))}")
end
database = "quickflow_demo_#{SUFFIX}"
admin.exec("CREATE DATABASE #{PG::Connection.quote_ident(database)} OWNER #{PG::Connection.quote_ident(roles.fetch('provision'))}")
admin.exec("COMMENT ON DATABASE #{PG::Connection.quote_ident(database)} IS #{admin.escape_literal("quickflow-production-demo:#{ID}")}")
admin.exec("GRANT pg_read_all_settings TO #{PG::Connection.quote_ident(roles.fetch('provision'))} WITH INHERIT TRUE")
admin.finish
admin = PG.connect(host: "127.0.0.1", port: DB_PORT, dbname: database, user: admin_name)
admin.exec("GRANT EXECUTE ON FUNCTION pg_control_system() TO #{PG::Connection.quote_ident(roles.fetch('provision'))}")
target = { "version" => 1, "isolation_id" => ID, "database" => database, "runtime_role" => roles["runtime"], "provision_role" => roles["provision"],
  "host" => "127.0.0.1", "port" => DB_PORT, "https_port" => HTTPS_PORT, "storage_root" => STORAGE,
  "allowed_host" => "qfd-#{SUFFIX}.localhost", "data_directory" => CLUSTER, "system_identifier" => system_id }
target_path = File.join(CONTROL, "target.json")
File.write(target_path, JSON.pretty_generate(target))
env = BASE_ENV.merge("RAILS_ENV" => "production", "QUICKFLOW_DEMO_PROFILE" => "production", "QUICKFLOW_DEMO_TARGET" => target_path,
  "QUICKFLOW_DEMO_SESSION_SECRET" => SESSION_SECRET, "QUICKFLOW_GUEST_LOGIN" => "true")
urls = roles.to_h { |kind, role| [ kind, "postgresql://#{role}:#{ROLE_PASSWORDS.fetch(kind)}@127.0.0.1:#{DB_PORT}/#{database}" ] }
provision_env = env.merge("QUICKFLOW_DEMO_DATABASE_URL" => urls.fetch("provision"), "QUICKFLOW_DEMO_PROVISION" => "true")
File.open(File.join(CONTROL, "private-test-context.json"), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
  file.write(JSON.generate(env: env, urls: urls, roles: roles, target: target, admin_name: admin_name))
end
command!("provision-first", provision_env, "bin/rails", "demo:provision")
command!("provision-second", provision_env, "bin/rails", "demo:provision")
puts "Fresh production-demo provision twice completed; control=#{CONTROL} port=#{DB_PORT}"
admin.finish
