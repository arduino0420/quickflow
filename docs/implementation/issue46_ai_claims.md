# Issue 46: short AI processing claims

External AI calls run between two short transactions. The first admits one
worker and captures the inputs. The second reads fresh records, checks ownership
and every relevant input, then saves the entire outcome atomically. Neither the
AI request nor local PDF download/validation holds these database locks.

| Path | Claim and snapshot | External work | Finalize |
|---|---|---|---|
| Questions | Assignment → existing durable request; selected pointer, blob, attachment, teacher, captured request model/prompt | Open captured blob, upload with one-hour expiry, `store:false`, validate response | Same selected request/token/owner/input; all Questions and success in one transaction |
| Reading | Assignment → Submission → attachments/blobs; ready → reading, new token; generation, student, teacher, exact answer blob and saved reading | Read captured blob only when reading absent | Same stage/token/time/generation/inputs; save reading and return to ready |
| Grading | Assignment → Submission → Questions → attachments/blobs; validate reading and saved Questions; ready → grading | Grade captured reading/questions/rules/source identities | Recheck all inputs, attachment identities and current generation-request pointer; all results and completed in one transaction |
| Deletion | Existing lifecycle advisory lock → Assignment → Submissions → Questions | Existing storage cleanup after commit | Protected deletion remains unchanged |

No new visible status or retry UI is added. Nullable Submission claim columns
have no default or backfill. NULL means unknown legacy work and cannot authorize
any reading or grading replay. New actual submissions become ready inside their
existing save transaction. The existing owner/flag/queue/input-checked grading
recovery alone can advance processing_generation and reset ready admission.
Reading recovery is not introduced.

A running token is never reclaimed based on elapsed time. A lost worker remains
visible through its stage/token/claimed_at for operator diagnosis. Successful
reading retains its token/time in ready state so an enqueue failure can identify
that exact admission. A newer claim or transition fences delayed queue errors.
Failure after a rolled-back final save uses a fresh transaction and the same
ownership/input fence. Unrelated title, score configuration or timestamp changes
do not invalidate AI inputs. Saved readings and valid saved Questions are reused.
The generation ledger retains A→B→A history and its captured model.

Deletion can commit while an external request is paused. Already-issued AI calls
may still finish; no cancellation is promised. Late success/error cannot recreate
records or fan out. Existing upload lifecycle locks and teacher staging semantics
remain. File cleanup scheduling, one-hour expiry, `store:false` and metadata-only
failure logging remain; no prompts, PDFs or response payloads enter logs.

## Future production cutover (not executed)

The additive migration requires a separately owner-approved coordinated web and
worker deployment. Stop admitting work, drain old queued/running AI work and
reconcile ambiguous legacy submissions and durable generation requests before
switching both web and workers. Do not infer unused work from NULL claim fields,
backfill ready, replay old jobs, or take over old tokens by age. Reconcile each
ambiguous item through the approved operational process; only existing eligible
explicit grading recovery can admit grading again. This change does not grant
permission for a live migration, AI call, AWS operation or deployment.

Rollback must drain and reconcile active new claims before older workers are
allowed to run. Blindly restarting old workers against active new claims defeats
the fencing protocol. Leave the nullable additive columns in place; do not drop
them or rewrite existing generation history as a rollback shortcut.

Demo manifests digest every Submission attribute, including the new nullable
fields. Synthetic claims stay nil and read-only. Old manifests fail closed;
there is no auto-rebaseline, reset or repair. Unknown-table/non-demo guards stay.

## Observing locks and testing

On an authorized isolated PostgreSQL target, `pg_stat_activity` and
`pg_blocking_pids(pid)` can distinguish a short claim/finalize wait from an
external API wait. During a paused stubbed AI response, the worker must have no
open transaction and deletion/duplicate workers must finish before releasing the
response barrier. Tests use committed records and separate connections. Upload
wait assertions remain because their lifecycle protection is intentional.
