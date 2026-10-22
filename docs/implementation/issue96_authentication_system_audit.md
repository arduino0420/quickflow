# Issue #96: authentication and access System Spec audit

Scope: existing login and authorization only, based on main `c87a2ae3ec56e5e720c64c3bd0f67c0ee33b785e`.
The DPro criteria supplied for this task require browser proof of login, model CRUD and access restrictions, with passing specs. Full CRUD remains #97; screen auditing (#95) and production-demo configuration (#93) are separate. This change adds no application behavior, routes, dependencies or permissions.

## Role × operation × allowed/denied evidence

Paths below are relative to `spec/system/`. New examples are in `authentication_access_spec.rb` (14 examples); existing evidence is reused rather than copied. All new examples use Selenium headless Chrome, real forms, cookies and controller requests.

| Role | Operation / boundary | Allowed evidence | Denied evidence |
| --- | --- | --- | --- |
| Teacher / student / admin | Login and destination | Existing `footer_spec.rb:35` follows all three real login forms to their respective destinations | New wrong-password examples for all three roles; student also changes school, grade, class and attendance number individually |
| Teacher | Logout and browser history | Existing `teacher_cache_privacy_spec.rb:16` | Existing logout → Back cannot restore grades |
| Student | Logout and browser history | New logout via existing list button | New Back and direct quiz URL cannot restore the private list; business data unchanged |
| Admin | Logout and browser history | New logout via existing header button | New Back and direct teacher-list URL cannot restore account information; business data unchanged |
| Existing roles | Switch identities | New teacher → student → admin → teacher and admin → student via existing login forms | Previous role's protected URLs require login again; account credentials and business data unchanged |
| Unauthenticated | Direct protected URLs | Public login forms remain available | New teacher list/detail, teacher student registration, student quiz, admin teacher/student lists redirect to the appropriate login |
| Teacher / student | Admin navigation and controller access | Existing role's list remains usable after refusal | New absence of admin links/form actions, direct admin URLs, and an admin account PATCH through Chrome; redirects to admin login, business data unchanged |
| Teacher | Other creator, including a shared assigned class | Own quiz edit and answer form render; the creator can submit the identical target-only grading payload successfully | New peer creator's quiz/detail/edit/answer/PDF GETs return 404; quiz PATCH/DELETE and grading PATCH return 404; real answer, grading and account records unchanged |
| Teacher | Other school | Own edit form renders | New foreign quiz GET/PATCH return 404; business data unchanged |
| Teacher | Student registration | New own-class registration succeeds and retains teacher session | New same-school unassigned class and other-school registration POSTs return 404; existing students unchanged |
| Student | Quiz distribution | New own-class quiz remains linked and its submission form renders | New undistributed, other-class and other-school quiz GET/POSTs return 404; valid synthetic PDF is included in the denied submission attempts; no submission/storage changes |
| Admin | School boundary | New own teacher listing and teacher/student edit forms render | New foreign teacher absent from list; foreign teacher/student edit GETs and teacher PATCH, student confirmation POST/PATCH/DELETE return 404; business data unchanged |
| Student | Same-student reauthentication | Existing `student_pdf_preview_spec.rb:73` resumes ink and submits once | Existing `:172` blocks stale saving/submission after another student logs in; `:35` and `:295` cover credential revocation |
| Guest | Entry, switching, logout and history | Existing `guest_browsing_spec.rb:31` uses **rack_test**, not Chrome; guest Request Specs provide additional HTTP coverage | Existing **Chrome** `guest_browsing_spec.rb:57` prevents private history restoration; #110's bounded seed-fixture helper is retained |

There is no teacher-side student edit/delete route to test. A shared class grants registration, not ownership of another teacher's quiz or answers. An owner's unpublished quiz detail is intentionally permitted by the existing controller; the undistributed-quiz denial above applies to students.

## Method and isolation

- Login and normal navigation use existing labels, h1 headings and buttons; no document-title assumptions or fixed sleeps.
- Adversarial writes serialize a real rendered form using browser `FormData`, change the target/fields and use same-origin browser `fetch` with the real session, forwarding a CSRF token only if present. Ordinary test configuration disables CSRF protection; these assertions prove authentication/authorization, not CSRF protection. No global CSRF setting is changed. HTTP status and redirect destination are asserted against actual controllers.
- The grading attempt removes the original form's two judgment field groups before adding only the target answer's valid result IDs. After asserting refusal and unchanged records, the actual creator submits the identical payload successfully, ruling out unrelated result-ID integrity rejection as a false positive.
- Rejected writes compare snapshots of schools, accounts, classes, assignments, questions, answers, grades, drafts and Active Storage records. Authentication throttle bookkeeping is intentionally excluded because login attempts update it.
- All records/PDFs are synthetic. RSpec's existing OpenAI client prohibition remains in force. No real AI, AWS, production data, seed changes or weakened NOWAIT behavior.
- The guest entry/switch/logout example at `guest_browsing_spec.rb:31` is a System Spec using rack_test; it is not claimed as real-browser evidence. The guest history example at `:57` explicitly uses Chrome. No duplicate guest suite is added here.
- Request Specs are supplementary HTTP evidence, not a substitute for the real-Chrome cases listed above.
- Local clone: `task-11/quickflow`; original `~/workspace/quickflow` untouched. New PostgreSQL cluster: `task-11/pgdata`, `127.0.0.1:56496/quickflow_test`; both `DATABASE_URL` and `PRIMARY_DATABASE_URL` explicitly select this database. Rails connection host/port/database and PostgreSQL `data_directory` were checked before migration. Storage resolves to this clone's `tmp/storage`.

## Validation

- Focused student/admin boundary checks: 2 examples, 0 failures.
- RuboCop: 236 files, no offenses. Brakeman: 0 errors, 0 security warnings.
- Full System Specs plus 15 related Request Spec files: **478 examples, 2 failures** (15m21s). All 14 new examples and all related Request examples passed. Log: `task-11/related-rspec.log`.
- Both failures are in unchanged `student_pdf_preview_spec.rb`: `:1058` hit a Selenium script timeout in PDF rotation/export; `:1200` did not finish a second-browser login within the existing wait. Rerunning only these two with ordinary settings passed the login case, while export still timed out (2 examples, 1 failure; `existing-pdf-focused.log`).
- Diagnostic only, without repository changes: running the export example with `Capybara.default_max_wait_time = 10` passed all assertions (1 example, 0 failures; `existing-pdf-diagnostic.log`). This establishes a local wait-budget sensitivity, not a normal-settings full-suite pass. No existing test or application timeout was changed.
- Before the final review correction, head `2f115285` passed all four CI jobs and full RSpec (1,795 examples, 0 failures; run `39747781972`). Latest main `a483aae` was subsequently merged normally; final review fixes must be checked on their own head.
- After that main merge and the grading-payload review correction, the new Chrome suite passed **14 examples, 0 failures** with ordinary test settings (`reviewed-auth-rspec.log`, 1m09s). RuboCop after main integration checked 238 files with no offenses; the subsequently adjusted spec also passed targeted lint.
- Final-head full RSpec and remaining security/dependency checks run in the draft PR's existing CI. The PR checks and test-job log are the source of truth for that exact head; do not infer success from this audit. No issue closure or merge is performed here; the parent task must independently review first.
