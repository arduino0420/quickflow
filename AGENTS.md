# QuickFlow Development Instructions

## Project Overview

QuickFlow is a Rails application for supporting junior high school mathematics quizzes.

The MVP aims to reduce teachers' workload by supporting the flow from quiz distribution to student submission, AI grading, teacher review, score calculation, and grade export.

Do not add features or requirements that have not been explicitly approved.

## Development Environment

- Ruby 4.0.6
- Ruby on Rails 8.1.4
- PostgreSQL 18.6
- RSpec Rails 8.0.4

Use the versions defined in the repository as the source of truth.

## Basic Development Workflow

For implementation work, follow this cycle:

1. READ
   - Inspect the current code and relevant files.
   - Do not assume the current implementation.

2. PLAN
   - Explain what files need to change and why.
   - Do not modify files during the planning step.

3. HUMAN CHECK
   - Wait for the user to review and approve the plan before implementation.

4. IMPLEMENT
   - Make only the approved changes.
   - Keep each implementation small and focused.

5. TEST
   - Add or update RSpec tests for implemented behavior.
   - Run the smallest relevant test first.

6. VERIFY
   - Report what changed, what was tested, and the results.

7. COMMIT
   - Do not commit unless explicitly instructed by the user.

## Requirements and Design Rules

- Do not invent or silently change application requirements.
- Do not add tables, columns, validations, enums, callbacks, or business rules unless they are part of the approved design or explicitly approved by the user.
- If the current design is unclear or inconsistent, stop and report it as a confirmation item before implementation.
- Prefer the existing requirements documents, table definitions, ER diagram, screen transition diagram, wireframes, and README over assumptions.
- Keep the MVP scope small. Do not add future features unless explicitly requested.

## Rails Implementation Rules

- Follow standard Rails conventions unless there is an approved reason not to.
- Keep controllers focused on request/response flow.
- Put data relationships and validations in models when appropriate.
- Use database foreign keys for approved relationships.
- Use database unique indexes for approved uniqueness constraints.
- Do not add database CHECK constraints unless explicitly approved.
- Do not add dependent deletion behavior unless explicitly approved.
- Do not change database structure outside migrations.
- Do not edit schema.rb manually.

## Testing Rules

- Use RSpec for new QuickFlow tests.
- Add tests for important implemented behavior.
- Test validations, associations, uniqueness rules, enums, and important business behavior where relevant.
- Do not remove the existing Minitest setup unless explicitly approved.
- Do not add testing libraries such as FactoryBot or Shoulda Matchers unless explicitly approved.

## Gem and Dependency Rules

- Do not add, remove, or upgrade gems without explicit approval.
- Before adding a gem, explain why it is needed.
- Do not change Ruby, Rails, PostgreSQL, or major dependency versions without explicit approval.

## Database Rules

The approved MVP currently uses these application tables:

- schools
- teachers
- classrooms
- students
- assignments
- assignment_classrooms
- questions
- submissions
- grading_results

Active Storage tables are separate framework-managed tables and should be introduced only when the Active Storage implementation step is approved.

## AI and Grading Rules

- Do not change the approved grading categories or grading workflow without explicit approval.
- Do not make uncertain handwritten answers appear certain.
- Preserve the distinction between AI judgment and teacher judgment.
- Keep traceability information for AI-generated answers and grading where defined by the approved design.

## Safety Rules for Changes

- Prefer small changes over large multi-feature changes.
- Before modifying existing code, inspect it first.
- Do not overwrite unrelated user changes.
- Do not delete files or data unless explicitly approved.
- Do not run destructive database commands such as db:drop, db:reset, or destructive SQL unless explicitly approved.
- If a command may destroy or overwrite data, explain the risk and ask before running it.

## Communication

When reporting work:

- Explain what changed.
- Explain why it changed.
- List files changed.
- Report tests or commands run.
- Report any remaining concerns or confirmation items.
- Use beginner-friendly explanations when possible.

## QuickFlow Learning Site

When the user requests an explainer explanation about QuickFlow, read
`docs/learning/AGENTS.md` and automatically create or update the article,
regenerate the learning site and article index, and run the necessary checks.
These documentation updates are authorized without a separate HUMAN CHECK.
Reuse an existing article for the same topic unless the user requests a separate article.
Explicit READ/PLAN-only or no-file-change instructions take precedence.
This authorization does not permit changes to application code, dependencies
outside docs/learning, existing CI, commits, pushes, or publishing.
