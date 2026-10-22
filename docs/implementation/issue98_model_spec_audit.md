# Issue #98: model validation and scope audit

Audited against main `a4426ce1de70dfdc6c5a470dad31cabf15a98505` (2026-10-22).
This change proves existing behavior; no model, schema, locale, dependency or UI changes.
Spec paths below are relative to `spec/`. “Existing” means verified in the baseline,
“Added” means the missing proof supplied here. This is a validation-level audit,
not exhaustive branch coverage of handwritten geometry or every PostgreSQL constraint.

## Validation, association and scope matrix

| Model | Existing rules and successful/failed evidence | Corresponding specs / change |
| --- | --- | --- |
| School | `school_code` presence, global uniqueness, ASCII alphanumeric format: accepted upper/lower case, nil/empty/whitespace/non-ASCII/punctuation/newline, duplicate | `models/school_spec.rb` — existing |
| Teacher | Required school; `user_id` presence/global uniqueness; immutable ID on update; secure password presence/confirmation/72-byte limit; password-policy callback only for persisted changed digest | `models/teacher_spec.rb` — existing association, blank/duplicate/cross-school uniqueness, update rejection, authentication and unchanged-password success. Moved/expanded legacy-policy example proves unchanged digest, rejected short password with password errors/old digest, successful replacement and old password rejection. |
| Admin | Required school; `user_id` presence/global uniqueness; secure password presence/confirmation/72-byte limit; password-policy callback on persisted changed digest | `models/admin_spec.rb` — existing association, blank/duplicate/cross-school uniqueness, confirmation and byte boundaries, unchanged-password success. Moved/expanded policy example proves legacy acceptance, invalid update/old digest preservation and valid replacement. Creation still permits legacy short passwords. |
| Classroom | Required school; grade presence/integer 1–6; class number presence/integer 1–15/unique within school+grade | `models/classroom_spec.rb` — existing accepted bounds/all grades, missing, out-of-range, fractional/non-numeric, duplicate, other-school/grade/number success and associations |
| Student | Required classroom; attendance number presence/integer 1–40/unique within classroom; secure password presence/confirmation/72-byte limit; password-policy callback on persisted changed digest | `models/student_spec.rb` — existing missing/range/type/duplicate/other-classroom success and authentication. Moved legacy 15-digit credential example, expanded with short update rejection, password error and old digest preservation; valid eight-digit replacement. |
| TeacherClassroom | Required teacher/classroom; pair uniqueness; teacher and classroom same school | `models/teacher_classroom_spec.rb`, `models/related_integrity_spec.rb` — existing missing/duplicate/foreign school/update rejection and unchanged persisted link; colleague/multiple-classroom success |
| Assignment | Required teacher; title presence; points presence/integer ≥1; `distributed_to_school(school_id)` | `models/assignment_spec.rb` — existing missing title/teacher, integer minimum and invalid types. Added scope examples: target inclusion, other-school-only and undistributed exclusion, multiple same-school distributions return one record, no matching distributions return empty. |
| AssignmentClassroom | Required assignment/classroom; pair uniqueness; classroom in assignment teacher’s school | `models/assignment_classroom_spec.rb`, `models/related_integrity_spec.rb` — existing missing, duplicate, cross-school create/update failure and saved link preservation; same-school colleague/different pair success |
| Question | Required assignment; presence of label/text/correct answer/generation model/prompt version/generated timestamp; position presence/integer ≥1/unique within assignment | `models/question_spec.rb` — existing all required fields nil/empty/whitespace, integer bounds/types, duplicate and alternate assignment/position success. Optional `grading_rule` NULL and plaintext remain accepted. |
| Submission | Required assignment/student; status and submitted timestamp presence; pair uniqueness; assignment teacher and student same school and distribution to student classroom; four-value status enum | `models/submission_spec.rb`, `models/related_integrity_spec.rb` — existing valid/absent/duplicate/alternate pair, enum mappings and invalid string/integer, missing associations, undistributed/cross-school/corrupt distribution/update failures; colleague-owned distributed classroom success |
| GradingResult | Required submission/question; presence of AI judgment/model/prompt version/graded timestamp; pair uniqueness; question in submission assignment; reading-confidence/AI/teacher enums; `pending_review` | `models/grading_result_spec.rb`, `models/related_integrity_spec.rb` — existing required/blank/duplicate/alternate pair, enum mappings/invalid values/nullable optional enums, cross-assignment create/update failure and valid association. Existing dedicated pending-review spec includes needs-review without teacher judgment and excludes reviewed/correct/incorrect results; no duplicate added. |
| AnswerDraft | Required student/assignment; pair uniqueness; 64 lowercase hex fingerprint; format version inclusion `[1]`; page-data validator | `models/answer_draft_spec.rb` — added missing associations and nil/empty/63/65-character/uppercase/non-hex fingerprint failures, alternate student/assignment success; strengthened duplicate error assertion. Fixed invalid-version proof to restore valid geometry first and assert format-version inclusion error with no page-data error. Existing valid persistence supplies success for fingerprint/version/associations; page-data malformed shape/coordinates/duplicate IDs/tool/width failure and exact page/point/operation/4 MiB capacity limits, exceeded limits, optimistic lock and logging filter reused. |
| AuthenticationAttemptBucket | Only custom primary key `key_digest`; no model validation, required association, enum or scope | No model validation/scope example is applicable. `services/authentication_throttle_spec.rb` and `services/authentication_concurrency_spec.rb` exercise internal storage through its owning services. No validation or CRUD invented merely to create a model spec. |
| ApplicationRecord | Abstract base class; no domain validation or scope | Not applicable |

Rails enum-generated scopes follow the tested mappings; the two explicit domain scopes
are listed above. PasswordPolicy’s pure algorithm tests stay in its service spec.

## Database agreement

Reviewed `db/schema.rb` against each association/uniqueness/presence declaration.
Existing model specs explicitly bypass validation inside savepoint transactions to prove
NOT NULL, unique indexes and foreign keys for schools, teachers, admins, classrooms,
students, assignments, both join tables, questions, submissions and grading results.
`AnswerDraft` already proves the student+assignment unique index; schema also contains
its two NOT NULL foreign keys, non-null fingerprint/version/page-data and defaults.
Those constraints agree with the model; this change does not add a redundant suite for
every constraint. `AuthenticationAttemptBucket` retains its primary key and NOT NULL
attempts/expiry columns, enforced through existing service behavior.

The database intentionally does not mirror all numericality, format, enum or school
consistency rules with CHECK constraints. No new contract or migration is introduced.
Nullable legacy `classrooms.teacher_id`, optional question grading rule, optional grading
fields and enum nullability are preserved. Active Storage framework tables are unchanged;
existing assignment/submission attachment examples exercise their integration.

## Verification and example accounting

Dedicated fresh PostgreSQL cluster: task-local `pg-issue-98`, `127.0.0.1:56498`,
database `quickflow_test`. Before migration, the real Rails connection reported that
host, port, database and data directory; both `DATABASE_URL` and
`PRIMARY_DATABASE_URL` were explicitly set to this isolated URL. No existing DB was
reset, seeded, dropped or stopped. RSpec disables construction of real OpenAI clients.

Command: `bundle exec rspec spec/models spec/services/password_policy_spec.rb`.
Baseline: **381 examples, 0 failures**. After: **393 examples, 0 failures**.
Model examples: **366 → 381**; PasswordPolicy service examples: **15 → 12**.
The removed three service examples were moved/expanded into the three model specs,
not deleted coverage. Net new examples: 10 AnswerDraft + 2 Assignment scope = 12.
The invalid-version proof was repaired inside an existing example. No other tests removed.

Local static checks: RuboCop over the repository and Brakeman (79 checks, zero warnings).
Final-head full RSpec and remaining security checks are run by the draft PR CI.
