#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
run_id="qf$(date -u +%Y%m%d%H%M%S)$(openssl rand -hex 3)"
network="${run_id}_net"
database="${run_id}_db"
application="${run_id}_app"
results="perf/http_load/results/${run_id}"
mkdir -p "$results"
printf '%s\n' "$run_id" > "$results/run_id.txt"
password="$(openssl rand -hex 24)"
stage="setup"

cleanup() {
  status=$?
  trap - EXIT
  printf 'stage=%s\nexit=%s\n' "$stage" "$status" > "$results/exit.txt"
  for container in "$application" "$database"; do
    if docker container inspect "$container" >/dev/null 2>&1; then
      if [[ "$(docker inspect -f '{{ index .Config.Labels "quickflow.http_load.run_id" }}' "$container")" != "$run_id" ]]; then
        echo "unowned container found; trial assets retained" >&2
        exit 1
      fi
      docker stop --time 15 "$container" >/dev/null || { echo "container stop failed; trial assets retained" >&2; exit 1; }
    fi
  done
  for container in "$application" "$database"; do
    if docker container inspect "$container" >/dev/null 2>&1; then docker rm -v "$container" >/dev/null; fi
  done
  if docker network inspect "$network" >/dev/null 2>&1; then
    if [[ "$(docker network inspect -f '{{ index .Labels "quickflow.http_load.run_id" }}' "$network")" != "$run_id" ]]; then
      echo "unowned network found; trial assets retained" >&2
      exit 1
    fi
    docker network rm "$network" >/dev/null
  fi
  printf '%s\n' "cleanup complete for $run_id" > "$results/cleanup.txt"
  exit "$status"
}
trap cleanup EXIT

docker network create --internal --label "quickflow.http_load.run_id=$run_id" "$network" >/dev/null
stage="network"
test "$(docker network inspect -f '{{.Internal}}' "$network")" = true

docker run -d --name "$database" --network "$network" --network-alias db --label "quickflow.http_load.run_id=$run_id" \
  -e POSTGRES_DB=quickflow_test -e POSTGRES_USER=load -e "POSTGRES_PASSWORD=$password" \
  postgres:18.6 >/dev/null
stage="database"
for i in $(seq 1 60); do
  if docker exec "$database" pg_isready -U load -d quickflow_test >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "$database" pg_isready -U load -d quickflow_test >/dev/null

docker run -d --name "$application" --network "$network" --user 1000:1000 --label "quickflow.http_load.run_id=$run_id" \
  -e RAILS_ENV=test -e RAILS_MAX_THREADS=3 -e "QUICKFLOW_HTTP_LOAD_RUN_ID=$run_id" \
  -e "SECRET_KEY_BASE=$(openssl rand -hex 64)" \
  -e "DATABASE_URL=postgresql://load:${password}@db:5432/quickflow_test" \
  "${QUICKFLOW_HTTP_LOAD_IMAGE:-quickflow-http-load:local}" sleep infinity >/dev/null
stage="application"
unset password

test "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$application")" = '{}'
test "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$database")" = '{}'
docker exec "$application" ruby -rsocket -e 'begin; Socket.tcp("1.1.1.1", 443, connect_timeout: 2); abort "external egress available"; rescue Errno::ENETUNREACH, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, IOError, SocketError; end'
stage="credentials"
docker exec "$application" sh -c 'test ! -e config/master.key && test ! -e config/credentials.yml.enc && test ! -e config/credentials && test -z "${OPENAI_API_KEY:-}" && test -z "${RAILS_MASTER_KEY:-}" && test -z "${SOLID_QUEUE_IN_PUMA:-}" && test ! -d storage/30'
stage="mounts"
docker exec "$application" ruby -e 'abort "unexpected mounts" unless File.read("/proc/self/mountinfo").scan(%r{ /rails/(?:storage|tmp|config|var/run/docker.sock) }).empty?'
stage="schema"
docker exec "$application" bin/rails db:schema:load
stage="fixture"
docker exec "$application" bin/rails runner perf/http_load/fixture.rb > "$results/fixture_check.json"
ruby -rjson -e 'r=JSON.parse(File.read(ARGV.fetch(0))); abort "fixture safety check failed" unless r.fetch("database")=="quickflow_test" && r.fetch("db_host")=="db" && r.fetch("storage_root")=="/rails/tmp/storage" && r.fetch("csrf")==true && r.fetch("adapter")=="HttpLoadRecordingAdapter" && r.fetch("job_execution_guard")==true' "$results/fixture_check.json"
docker exec -d "$application" sh -c 'bin/rails server -b 127.0.0.1 -p 3000 >tmp/http_load_server.log 2>&1'
stage="server"
for i in $(seq 1 60); do
  if docker exec "$application" ruby -rnet/http -e 'exit(Net::HTTP.get_response(URI("http://127.0.0.1:3000/student/login")).code == "200" ? 0 : 1)' >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "$application" ruby -rnet/http -e 'abort "server unavailable" unless Net::HTTP.get_response(URI("http://127.0.0.1:3000/student/login")).code == "200"'
docker exec "$application" ruby -e 'commands = Dir.glob("/proc/[0-9]*/cmdline").reject { |f| f == "/proc/#{Process.pid}/cmdline" }.map { |f| File.read(f).tr("\0", " ") rescue "" }; abort "job worker found" if commands.any? { |c| c.match?(/solid_queue.*(?:start|supervisor|worker)/i) }'
stage="csrf"
docker exec "$application" ruby perf/http_load/client.rb safety > "$results/csrf_check.json"
stage="preflight_data"
docker exec "$application" bin/rails runner perf/http_load/verify.rb > "$results/preflight_data.json"
ruby -rjson -e 'r=JSON.parse(File.read(ARGV.fetch(0))); a=r.fetch("canary"); abort "canary verification failed" unless a.values_at("submissions","unique_students","readable_pdfs","generation_zero","reading_jobs","distinct_job_submissions","distinct_job_ids") == [1,1,1,1,1,1,1] && a.fetch("grading_results")==0 && a.fetch("other_jobs")==0' "$results/preflight_data.json"

docker exec "$application" ruby perf/http_load/client.rb ordinary > "$results/ordinary.json"
stage="handwritten"
docker exec "$application" ruby perf/http_load/client.rb handwritten > "$results/handwritten.json"
sustained_modes="${QUICKFLOW_SUSTAINED_MODES:-sustained_legacy sustained_append}"
for mode in $sustained_modes; do
  case "$mode" in sustained_legacy|sustained_ack|sustained_append) ;; *) echo "unknown sustained mode" >&2; exit 1 ;; esac
  stage="$mode"
  docker exec "$application" ruby perf/http_load/sustained.rb "$mode" > "$results/$mode.json"
done
stage="sustained_verification"
docker exec -e "QUICKFLOW_SUSTAINED_MODES=$sustained_modes" "$application" bin/rails runner perf/http_load/verify_sustained.rb > "$results/sustained_verification.json"
stage="verification"
docker exec "$application" bin/rails runner perf/http_load/verify.rb > "$results/verification.json"
ruby -rjson -e 'r=JSON.parse(File.read(ARGV.fetch(0))); %w[ordinary handwritten].each { |mode| a=r.fetch(mode); abort "#{mode} verification failed" unless a.values_at("submissions","unique_students","readable_pdfs","generation_zero","reading_jobs","distinct_job_submissions","distinct_job_ids") == [30,30,30,30,30,30,30] && a.fetch("grading_results")==0 && a.fetch("other_jobs")==0 }' "$results/verification.json"
docker exec "$application" ruby -rjson -e 'log=File.read("tmp/http_load_server.log"); puts JSON.generate(deadlocks: log.scan(/deadlock detected/i).size, timeouts: log.scan(/statement timeout|PG::QueryCanceled/i).size, openai_requests: log.scan(%r{https://api\.openai\.com/}).size)' > "$results/server_errors.json"
ruby -rjson -e 'r=JSON.parse(File.read(ARGV.fetch(0))); abort "server error found" unless r.values.all?(&:zero?)' "$results/server_errors.json"
printf '%s\n' 'passed' > "$results/result.txt"
