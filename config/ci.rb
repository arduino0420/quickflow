# Run using RAILS_ENV=test bin/ci against the isolated DB verified in README.
abort "Use RAILS_ENV=test and the isolated test database described in README." unless ENV["RAILS_ENV"] == "test"

CI.run do
  step "Dependencies", "bundle check"
  step "PDF parser", "bin/install-qpdf"
  step "Test schema", "bin/rails db:test:prepare"

  step "Style: Ruby", "bin/rubocop"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: JavaScript dependencies", "bin/audit-javascript"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  step "Tests: RSpec (including system tests)", "bundle exec rspec"

  # Demo seeds are opt-in and have their own isolated fixture specs in RSpec.
  # Do not clear logs/storage or replant database rows in this quality command.

  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
