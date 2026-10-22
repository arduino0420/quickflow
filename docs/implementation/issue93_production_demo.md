# Production-mode demo profile: isolated local validation

This is an explicit production-mode profile for synthetic demonstration data. It does not publish a demo or change ordinary QuickFlow deployment. Public deployment, AWS resources, billing, DNS, public certificates, existing roles/secrets, and school operations are outside this change.

## Identity and permissions

`QUICKFLOW_DEMO_PROFILE=production` selects the demo identity only with `RAILS_ENV=production`. `QUICKFLOW_GUEST_LOGIN=true` separately enables guest entry. Turning entry off retains the identity's server-side readonly, no-AI, no-job and normal-login restrictions. Existing valid guests retain their readonly access until their 15-minute nonce expires. An ordinary login or an old ordinary session cannot access demo business pages.

`QUICKFLOW_DEMO_PROVISION=true` is accepted only by the sole explicit top-level `demo:provision` Rake task. The runtime does not require it and rejects it. `bin/demo-web` runs a dedicated, zero-worker Puma configuration with verification before serving; it never invokes `db:prepare`. The ordinary Docker entrypoint and ordinary production configuration remain unchanged when the profile is OFF.

The runtime receives only its independent runtime URL and session secret. The provisioning URL belongs exclusively to the provisioning task. The runtime role must be LOGIN/NOINHERIT with no superuser, CREATEDB, CREATEROLE, replication, bypass-RLS, memberships, database/schema/object ownership, schema CREATE, database CREATE/TEMP, sequences, or business/metadata mutations. Business tables, Active Storage and Rails metadata receive SELECT only. `authentication_attempt_buckets` alone receives SELECT/INSERT/UPDATE/DELETE for nonce revocation and throttling, never TRUNCATE. Effective column privileges are checked as well as table privileges. Runtime verification bypasses Rails' query cache.

The shared verifier compares the declared token-derived database, roles, loopback endpoint, actual Rails/SQL database/host/port/current and session user, database marker, complete user schema/table inventory, role privileges and complete row/file manifest. Provisioning additionally verifies the newly created cluster's actual data directory and PostgreSQL system identifier before migration. Unknown schemas/tables/views, extensions/functions/foreign servers, redirected storage and stale manifests are rejected. An isolation marker prevents operator mistakes; it does not defend against a privileged administrator who deliberately changes the target, grants, or files.

The Disk root must be the dedicated absolute `tmp/production-demo-<32 hex isolation ID>` path with its matching marker and no symlinks. Its manifest includes every ordinary file, business/Active Storage table, Rails metadata and target contract. Authentication counters/nonces are the only excluded mutable state. Changes to schema/manifest contracts, including future #47 integration, require a new demo; do not automatically rebaseline or overwrite an existing demo.

Runtime CONNECT/CREATE/TEMP access to any other connectable database in the dedicated cluster is also refused. The fresh-cluster bootstrap removes PUBLIC access from its own postgres/template databases; synthetic sentinel access is granted only for the wrong-endpoint diagnostic and revoked in ensure. A subsequently added database with permissive PUBLIC grants makes runtime verification fail closed.

## Local verification harness

Use the repository's Ruby/PostgreSQL versions. `bundle exec ruby script/production_demo_smoke.rb` creates a **new** task-local cluster, dedicated database/roles/storage, verifies endpoint/process owner/data directory/system identifier, then explicitly provisions twice. It never accepts an existing database as a seed target. A partial provisioning failure is refused rather than repaired or reset.

The harness writes its nonsecret control-directory path to `tmp/production-demo-latest-control`. Its `private-test-context.json` has mode 0600 and contains temporary local credentials; do not print, commit, copy, or share it. Run `bundle exec ruby script/production_demo_verify.rb <absolute control directory>` to verify the runtime with a private, one-hour CA. The CA is trusted only by that verification client, with hostname and certificate verification enabled; no OS/browser trust configuration is changed. The HTTPS process binds only the declared 127.0.0.1 port and is stopped in ensure. Compile production assets before checking the HTML asset URLs. Do not use a browser certificate-warning bypass.

The runtime diagnostic checks effective DML/DDL denial, required auth CRUD, no AI/enqueue/execution/Disk mutation, null cache, primary-only configuration, and unchanged complete manifest. Its checks also run with guest entry OFF. The negative diagnostic `script/production_demo_negative_checks.rb` is a Rails runner **test harness** for the freshly created local cluster: it reads the private context to obtain the test administrator's name, verifies cluster identity, temporarily changes only synthetic-test grants/markers/files with ensure restoration, creates one new synthetic sentinel database, and verifies zero verifier SQL writes and sentinel/manifest invariance. It is never part of the web entrypoint and refuses sentinel database reuse.

Stop only the harness's recorded Puma PID and its own `pg_ctl -D <exact new cluster>` after verification. Retain redacted evidence; disable temporary test roles and remove private test context/server keys when no longer needed. Never stop existing services or drop/reset another database.

## Transport, sessions and background work

The profile requires a separate 128-hex session secret and a unique `__Host-qfd-<token prefix>` host-only cookie: Secure, HttpOnly, SameSite=Strict, path=/, no Domain. The target declares one exact host and HTTPS port. The middleware accepts direct TLS only, rejects Host mismatches and all Forwarded/X-Forwarded headers, and trusts no proxies. Guest entry uses existing CSRF protection, reset_session, credential digest proof, server allowlist and expiring/revocable nonce. Responses use no-store. Existing school/owner scopes and authenticated PDF controllers remain; standard Active Storage public routes stay disabled.

Demo cache uses null_store. No secondary cache/queue/cable configuration exists; Solid Queue supervision, Puma workers and recurring execution are absent. Even `SOLID_QUEUE_IN_PUMA=false` is refused because the ordinary Puma condition treats any present string as enabled. Enqueue, job execution and AiClient construction fail closed for demo identity even with guest entry OFF. Sample grading remains explicitly fictional, never claimed as an AI execution result.

Successful guest starts consume the existing raw-peer budget (10/10 minutes, shared by clients behind one proxy) and global budget (50/15 minutes). The verifier hashes the manifest before the entry throttle; this is not an ingress DoS defense. After verified starts, at most 100 already-expired auth rows are removed using the existing expiry predicate; active counters/nonces and business data are untouched.

## Technical acceptance and deployment are separate

Issue #92's implementation evidence covers classified initial business data (12 tables with at least five records, ten regular PDF attachments), an explicit isolated seed, complete integrity verification, refusal of existing data, and repeat execution without replacement. Authentication limits, Queue/Cache/Cable, variants and Rails metadata are operating state produced by genuine execution. Not fabricating those rows is an engineering application judgment; it is not an official DPro exemption or a claim that every physical table literally contains five rows.

Issue #93's technical evidence covers administrator and general-user guests (teacher/student), isolation, readonly scopes, credential/session switching, logout landing and revocation, CSRF and no-AI/no-job checks. Production-mode checks run on isolated local infrastructure with a CA/hostname-verifying HTTP client, including an already valid guest retaining readonly access when entry is disabled. A public URL is not an explicit Issue #93 checkbox. These implementation criteria are assessed from the text and evidence, separately from owner-approved deployment work; no additional mentor or public-deployment gate is imposed here.

## Before any public deployment

These are concrete deployment conditions, not additional DPro requirements or a requirement for mentor permission:

- Obtain the user's approval for deployment cost and operating method; no deployment is authorized here.
- Keep the provisioning credential and all school/AWS/OpenAI/master-key credentials absent from the runtime. Use a separately managed independent session secret, restricted process identity and private database connectivity.
- Mount seeded Disk data/manifest and the target declaration read-only for the web identity. The Ruby Disk guard and local file digests do not prove OS-level immutability or absence of a deployment-time bind mount. This task does not change OS security or create persistent access.
- Configure and verify real DNS, valid public TLS, HTTPS-only ingress, and the exact allowed hostname. This local client-CA verification does not establish Chrome/public-certificate behavior. Chrome HTTPS, browser history/cache behavior and public proxy behavior remain unverified unless separately evidenced.
- Set proxy rate/body/concurrency limits before the manifest verifier. The current transport accepts direct TLS only; a future proxy must strip untrusted forwarded headers and preserve the approved TLS/peer boundary. Do not silently start trusting X-Forwarded-For.
- Validate deployment-level no-worker/no-secondary-service/no-egress controls and effective role grants on the actual independent demo. Do not expose `RAILS_ENV=test` on the Internet.

Actual deployment and real infrastructure verification remain unperformed and belong to the existing deployment work. The conditions above govern that future operation, rather than adding checkboxes to Issues #92/#93. Historical review comments are not rewritten by this current clarification.
