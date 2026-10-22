# Issue #97: implemented CRUD and System Spec evidence

Initial baseline: `c87a2ae3ec56e5e720c64c3bd0f67c0ee33b785e`.
Integrated screen-audit main: `a483aaed3c46b2f26801c90c7b1199707e5b053e` (#95).
Final main integration: `25b28c7e61fce4d25406c7a4822adb357f08bacd` (Actions cache update only).
Reviewed #97 in full, root AGENTS.md, routes, every application model,
assignment/submission/student/admin controllers, related views, existing System,
Request and service specs. There is no additional repo testing skill.

## Interpretation and scope

The development requirement is implementation of CRUD features; the System
requirement says to test each model's CRUD features. This audit covers existing
direct and indirect operations. It does not claim an official exemption or that
every model has all four operations. The 2026-10-22 updated #97 body explicitly requires this implementation-based
interpretation and a recorded rationale, without an additional mentor stop. No
mentor answer or official exemption is claimed. Dangerous management screens must
not be added merely to manufacture CRUD. No application code, schema,
grading contract, dependencies, authentication or AI behavior is changed here.
#96 authentication System, #95 screen audit and #93 production-demo profile remain
separate work. Setup records below are preconditions, never evidence of browser C.

Legend (each cell explicitly identifies its evidence class):

* **既存System**: existing spec, real Chrome unless specifically marked rack_test.
* **追加System**: new real Chrome spec in this change.
* **Request-Serviceのみ**: implementation covered below browser level only.
* **機能なし**: no corresponding application operation; System対象なし.
* **運用処理**: internal/CLI/framework lifecycle, no CRUD management screen.

Paths in the table are relative to `spec/`. A cell may distinguish user and
operational variants of one operation. C/R/U/D refer to persisted rows, not to a
parent form's label: responsibility changes create/delete join rows, not UPDATE.

## Model × CRUD × screen × evidence

| Model | C | R | U | D |
|---|---|---|---|---|
| School | 運用処理: pre-provisioning/seed; no browser registration | 追加System: fixed school code on teacher/student registration and teacher list (`account_crud`); 既存System: student login and admin listings; Request-Serviceのみ: cross-school scope (`requests/admin_students`, `admin_teacher_editing`, `teacher_classroom_access`) | 機能なし: school edit UI | 機能なし: school delete UI |
| Admin | 運用処理: `accounts:create_admin` CLI (`tasks/accounts_admin`) | 既存System: admin authentication/dashboard (`system/admin_account_management`); account CRUD does not add an admin list | 機能なし: admin credential/profile update UI or dedicated update CLI | 機能なし: browser delete |
| Teacher | 追加System: admin registration (`system/account_crud`); 運用処理: `accounts:create_teacher` CLI (`tasks/accounts`) | 既存System: list/responsive actions (`system/admin_teacher_list_layout`); 追加System: saved teacher and school on list/edit (`account_crud`) | 既存System: password reset (`admin_account_management`); 追加System: blank password preserved, immutable teacher ID/school, responsibility edit and zero classes (`account_crud`); Request-Serviceのみ: forged identity/stale token guards (`requests/admin_teacher_editing`) | 機能なし: teacher deletion route/UI |
| Classroom | 追加System: indirectly from teacher registration/edit and unused student membership correction (`account_crud`); Request-Serviceのみ: admin student registration creates a class (`requests/admin_students`) | 追加System: reuses existing class and reads new classes in responsibility form/list and distribution (`account_crud`, `assignment_crud`); 既存System: student class filter (`admin_student_listing`) | 機能なし: classroom row editing; changing a student's membership does not update Classroom | 機能なし: classroom delete UI; removing teacher responsibility retains class |
| TeacherClassroom | 追加System: teacher registration and responsibility addition (`account_crud`); 運用処理: legacy backfill (`tasks/teacher_classrooms`, `services/teacher_classrooms/legacy_backfill`) | 追加System: selected checkboxes/list (`account_crud`); 既存System: teacher list (`admin_teacher_list_layout`) | 機能なし: row UPDATE; parent teacher form implements C/D | 追加System: remove one/all responsibilities, retain class/student/submission (`account_crud`) |
| Student | 追加System: admin and teacher registration, real forms (`account_crud`) | 既存System: scoped filtered/paginated list and account identity (`admin_student_listing`, `admin_account_management`); 追加System: target students in quiz detail (`assignment_crud`) | 既存System: attendance and password changes (`admin_account_management`); 追加System: safe unused membership correction, history-preserving number correction, draft/submission/source/destination distribution movement refusals (`account_crud`) | 既存System: unused account confirmation/cancel/explicit deletion (`admin_account_management`); 追加System: deletion denied with draft/submission/source distribution and records unchanged (`account_crud`); destination-only distribution does not forbid deleting an unused source account |
| Assignment | 追加System: PDF distribution to two classes (`assignment_crud`) and workflow (`quiz_grading_workflow`) | 追加System: teacher list/detail/target students/class filter; unrelated student/other teacher exclusion (`assignment_crud`); student list/PDF/result (`quiz_grading_workflow`); 既存System: PDF preview (`student_pdf_preview`) | 追加System: title cancel/whitespace rejection/save, unchanged PDF/distribution/questions/draft/submission/results/points (`assignment_crud`); 機能なし: PDF/points/distribution edit UI | 追加System: confirm cancel/accept; only selected dependency graph deleted (`assignment_crud`); Request-Serviceのみ: inconsistent/foreign data and rollback guards (`requests/assignment_deletion`, `services/assignment_deletion`) |
| AssignmentClassroom | 追加System: real distribution form persists two links (`assignment_crud`) | 追加System: destination list/filter/student scope (`assignment_crud`) | 機能なし: link UPDATE or distribution edit UI | 追加System: parent explicit deletion (`assignment_crud`); no standalone removal UI |
| Question | 追加System: real `QuestionGenerationJob`, fixed external API response, real persisted questions (`quiz_grading_workflow`) | 追加System: scoped rendered question text/correct answers on teacher review, and student results (`quiz_grading_workflow`) | 機能なし: editable question/answer UI; Request-Serviceのみ: generation retry/idempotency/failure internals (`jobs/question_generation_job`, `services/question_generator`) | 追加System: parent explicit deletion (`assignment_crud`); no individual delete UI |
| Submission | 追加System: handwritten PDF and legacy file-select upload with real enqueue/reading/grading (`quiz_grading_workflow`); 既存System: handwritten submission/recovery/lost response (`student_pdf_preview`) | 追加System: teacher summary/review iframe, student submitted PDF/results, downloaded Excel (`quiz_grading_workflow`) | 追加System: real job status/extracted text, existing flag OFF/ON recovery and processing generation, stale upload overwrite refusal (`quiz_grading_workflow`); 機能なし: student resubmission/edit UI | 追加System: parent explicit deletion (`assignment_crud`); no individual delete UI |
| GradingResult | 追加System: real `AnswerGradingJob` persistence (`quiz_grading_workflow`) | 追加System: per-question teacher/student judgment and score, Excel download distinguishes blank score from 0 (`quiz_grading_workflow`) | 追加System: teacher final judgment changes only `teacher_judgment`/timestamp, AI text/reasons/reading/questions unchanged, untouched judgments stay nil (`quiz_grading_workflow`); Request-Serviceのみ: legacy judgment clear-to-nil endpoint/optimistic concurrency (`requests/teacher_grading_reviews`, `final_judgment_ui`) | 追加System: parent explicit deletion (`assignment_crud`); no individual delete UI |
| AnswerDraft | 既存System: autosave from actual ink (`student_pdf_preview`); 追加System: workflow autosave pre-submission (`quiz_grading_workflow`) | 既存System: restore exact coordinates/ink (`student_pdf_preview`) | 既存System: appended ink, restore, session recovery/conflict, lost response keeps one submission (`student_pdf_preview`); 追加System: submission retains saved draft (`quiz_grading_workflow`) | 追加System: only parent explicit deletion (`assignment_crud`); clearing canvas is U (empty operations), submission retains row; no individual delete UI |
| AuthenticationAttemptBucket | 運用処理 / Request-Serviceのみ: failed authentication reserves internal counters (`services/authentication_throttle`, `requests/authentication_security`) | 運用処理 / Request-Serviceのみ: throttle reads locked counters; no account-management UI | 運用処理 / Request-Serviceのみ: increment/expiry window (`services/authentication_throttle`, `authentication_concurrency`) | 運用処理 / Request-Serviceのみ: successful authentication reset / expired `AuthenticationAttemptCleanupJob` batch cleanup (`services/authentication_throttle`); #96 owns authentication browser evidence |
| ActiveStorage::Attachment / Blob | 運用処理: framework-managed; 追加System: attached material/answer through actual forms (`assignment_crud`, `quiz_grading_workflow`) | 追加System: original material bytes, submitted PDF and teacher/student iframe (`assignment_crud`, `quiz_grading_workflow`) | 機能なし: attachment replacement UI; 追加System: stale submitted upload cannot replace blob (`quiz_grading_workflow`) | 追加System: attachment rows removed on parent deletion (`assignment_crud`); 運用処理: asynchronous `ActiveStorage::PurgeJob` physical purge (`services/assignment_deletion`); UI enqueue/row deletion is not proof of physical purge |
| ActiveStorage::VariantRecord | 運用処理: framework variants, no application CRUD UI | 運用処理: framework lifecycle | 機能なし: application edit UI | 運用処理: framework cleanup |
| ApplicationRecord | 機能なし: abstract base | 機能なし: abstract base | 機能なし: abstract base | 機能なし: abstract base |

Rails infrastructure (Solid Cache/Queue/Cable production databases) is operational,
not an exposed business-model CRUD feature. Demo fixture replacement is an explicitly
bounded operational seed, not a general delete screen or browser CRUD proof.

## Existing evidence reused without duplicate scenarios

`system/admin_account_management_spec.rb` already covers safe unused deletion/cancel,
attendance correction, student password reset and teacher password reset.
`system/student_pdf_preview_spec.rb` already covers draft C/R/U, exact restoration,
actual hand input, submission retry, duplicate/lost response, and privacy/recovery.
`system/teacher_cache_privacy_spec.rb` covers logout history. These remain unchanged.
`system/guest_browsing_spec.rb`'s main role-navigation example uses **rack_test**;
it is not counted as real Chrome CRUD. Only its explicit Chrome history example is
Chrome evidence. This change does not depend on guest seed locks.

## Verification record

Dedicated clone/branch: `quickflow-issue97`, `test/issue-97-crud-system-coverage`.
Fresh cluster: task-local `issue97-pgdata`, `127.0.0.1:5597/quickflow_test`.
Before migration the real Rails SQL endpoint reported database `quickflow_test`,
address `127.0.0.1`, port `5597`, and that dedicated data directory.
Both `DATABASE_URL` and `PRIMARY_DATABASE_URL` point there. Storage resolves to this
clone's `tmp/storage`. No other checkout/database/service was changed or reset.
RSpec prohibits real OpenAI constructors. The new workflow stubs `AiClient.build`'s
external client only, runs actual jobs once at bounded checkpoints, and uses real
PDF/ink/model persistence. Existing dependent records in the deletion scenario are
only preconditions; the workflow supplies their C evidence. Browser downloads are
read only after a bounded completion wait. No real student data or external AI used.

Execution results are recorded below after local checks and final-head CI. Evidence
availability above must not be read as a claim that every listed spec ran locally.

Local initial-baseline verification: **412 examples, 0 failures** (7m23s).
Included all 10 new Chrome examples; existing `admin_account_management`,
`admin_student_listing`, `admin_teacher_list_layout`, `teacher_cache_privacy`;
`student_pdf_preview` examples at lines 330, 1431, 1627 (draft restoration,
handwritten submission and lost response); and Request suites `assignment_names`,
`assignment_deletion`, `admin_teacher_editing`, `admin_teachers`, `admin_students`,
`admin_account_management`, `student_registration`, `student_submissions`,
`student_answer_drafts`, `teacher_grading_reviews`, `assignment_exports`,
`mvp_workflow`. The remaining PDF scenarios and lower-level suites are existing
evidence, not claimed as locally re-executed in that command.

Latest-main integration verifies the new browser workflow plus changed teacher
review/return-context and existing MVP Request suites. Full local RSpec is not
repeated; final-head CI owns the full suite.

Latest-main integration result: **141 examples, 0 failures** (2m22.8s):
`system/quiz_grading_workflow_spec.rb`, `requests/teacher_grading_reviews_spec.rb`,
`requests/submission_return_context_spec.rb`, `requests/mvp_workflow_spec.rb`.
RuboCop: **241 files, no offenses**. Brakeman: **79 checks, zero warnings**.
`git diff --check` passes. CI's complete RSpec and security checks are attached to
the draft PR; their final-head status must be checked before independent review.

Excel evidence refinement: the same Chrome workflow downloads the displayed Excel
before teacher correction and asserts numeric `0` (`C2` type `n`) against the
unsubmitted student's empty `C3`; it downloads again after correction and asserts
`5`/empty. Both use the same download helper and actual browser downloads. The
changed workflow alone passes **1 example, 0 failures** (49.41s), with RuboCop and
`git diff --check` passing. Final-head CI is rechecked after this test-only update.

The final evidence assertions also verify the unsubmitted row's `B3` attendance
number and the presence of its empty `C3` cell in both browser downloads; missing
rows/cells cannot pass as blank scores. Teacher review asserts rendered question
text and correct answers within each question article, and the student's
incorrect-result article asserts its correct answer. The amended Chrome workflow
passes **1 example, 0 failures** (12.26s); RuboCop and diff checks pass.
