#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
run_id="qfspec$(date -u +%Y%m%d%H%M%S)$(openssl rand -hex 3)"
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
  -e POSTGRES_DB=quickflow_test -e POSTGRES_USER=load -e "POSTGRES_PASSWORD=$password" postgres:18.6 >/dev/null
stage="database"
for i in $(seq 1 60); do
  if docker exec "$database" pg_isready -U load -d quickflow_test >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "$database" pg_isready -U load -d quickflow_test >/dev/null
docker run -d --name "$application" --network "$network" --user 1000:1000 --label "quickflow.http_load.run_id=$run_id" \
  -e RAILS_ENV=test -e RAILS_MAX_THREADS=10 -e SE_CHROMEDRIVER=/usr/bin/chromedriver \
  -e "SECRET_KEY_BASE=$(openssl rand -hex 64)" \
  -e "DATABASE_URL=postgresql://load:${password}@db:5432/quickflow_test" \
  quickflow-http-load:local sleep infinity >/dev/null
stage="application"
unset password
test "$(docker inspect -f '{{json .HostConfig.PortBindings}}' "$application")" = '{}'
docker exec "$application" ruby -rsocket -e 'begin; Socket.tcp("1.1.1.1", 443, connect_timeout: 2); abort "external egress available"; rescue Errno::ENETUNREACH, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, IOError, SocketError; end'
stage="schema"
docker exec "$application" bin/rails db:schema:load
stage="related_rspec"
related_status=0
docker exec "$application" bundle exec rspec spec/requests/thirty_student_submissions_spec.rb \
  spec/requests/student_submissions_spec.rb spec/requests/student_handwritten_submission_concurrency_spec.rb \
  > "$results/related_rspec.txt" 2>&1 || related_status=$?
full_status=0
stage="full_rspec"
docker exec "$application" bundle exec rspec > "$results/full_rspec.txt" 2>&1 || full_status=$?
printf 'related_exit=%s\nfull_exit=%s\n' "$related_status" "$full_status" > "$results/status.txt"
test "$related_status" -eq 0 && test "$full_status" -eq 0
