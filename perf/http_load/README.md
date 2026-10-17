# Isolated 30-student HTTP submission trial

Build the dedicated image while image and package downloads are allowed:

```sh
docker build -f Dockerfile.http-load -t quickflow-http-load:local .
```

Run the HTTP trial with Docker Desktop available:

```sh
bash perf/http_load/run.sh
```

The script creates one internal Docker network, one PostgreSQL 18.6 container,
and one app container per run ID. It publishes no ports or host mounts. Puma
listens on `127.0.0.1:3000` inside the app container, and the HTTP client runs
as another process in that container. The app uses a test-only Active Job
adapter, forbids job execution, and enables CSRF protection only for this run.
Preflight checks must pass before either 30-student trial starts. The script
stops and removes only its own containers and network. Its result directory
under `perf/http_load/results/` remains for review.

Run RSpec on a separate internal network and PostgreSQL container:

```sh
bash perf/http_load/test_suite.sh
```

The per-request times are real HTTP durations in the shared container. The
`sampled_advisory_wait_ms` value sums observed PostgreSQL advisory-lock waiters
over polling intervals; it is an estimate, not exact lock acquisition time for
individual requests. The maximum RSS is the peak sampled Puma process RSS.
These measurements describe this isolated environment and do not guarantee
production throughput.
