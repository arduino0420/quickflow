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

## Sustained autosave comparison

`run.sh` also runs `sustained_legacy` and `sustained_append` sequentially. Each phase
uses 30 separately authenticated synthetic students for 180 seconds, saving on a
5-second schedule. Every round adds eight 150-point pen/eraser operations plus
one later operation for the following checkpoint. Each student finishes with
48,450 saved points and one newer unsaved operation. The final HTTP upload is
a per-student marked fixture PDF, **not a browser-rendered handwriting PDF**.
Chrome system tests separately verify actual latest-ink PDF rendering.

The legacy phase uses the unchanged full-response protocol; the acknowledgment
phase sends `X-Draft-Response: acknowledgment`. The append phase also negotiates
`append_supported` through GET and sends only newly appended operations with the
last confirmed version. Both use the same current server, so a default run
compares protocols, not two independently deployed releases. An optional
`sustained_ack` mode measures acknowledgment responses with full request bodies.
Select phases with `QUICKFLOW_SUSTAINED_MODES`, for example
`QUICKFLOW_SUSTAINED_MODES=sustained_append bash perf/http_load/run.sh`.

The client checks exact GET contents periodically (including a simulated lost
save response), stale-version rejection, final coordinates and versions,
30 simultaneous submissions, same-attempt retries and different-attempt
rejection. `verify_sustained.rb` independently verifies persisted draft hashes,
student-specific PDF hashes, submission counts and exactly one reading job per
answer. It never runs the reading jobs or calls an AI service.

Results contain timing, byte totals, expected conflicts, sampled Puma RSS,
database connections and lock waiters. RSS is sampled every 10ms and includes
GC behavior and earlier trials; sequential phases are not isolated memory
benchmarks. Durations can exceed 180 seconds if requests fall behind. This is
local synthetic load evidence, not proof of iPad memory, WAN or production
capacity. There are no real student names, credentials or answer data in the
result summaries. Do not publish the private fixture file inside the container.

Use `QUICKFLOW_HTTP_LOAD_IMAGE` to select a prebuilt local trial image. Runtime
is still guarded by the same internal-network, no-host-mount, test-database,
CSRF and no-job-execution checks. The runner removes only containers and the
network labelled with its own run ID; result files remain locally.
