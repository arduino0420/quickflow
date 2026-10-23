require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"

RSpec.describe "Student PDF preview in Chrome", type: :system do
  before do
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    page.current_window.resize_to(1280, 900)
    page.driver.browser.execute_cdp("Browser.setDownloadBehavior", behavior: "deny")
    school = School.create!(school_code: "PDFSYS")
    teacher = Teacher.create!(school: school, user_id: "pdf-system", password: "password123")
    classroom = Classroom.create!(school: school, grade: 1, class_number: 1)
    Student.create!(classroom: classroom, attendance_number: 1, password: "password123")
    @assignment = Assignment.create!(teacher: teacher, title: "表示試験", point_per_question: 5)
    @assignment.assignment_classrooms.create!(classroom: classroom)
    @assignment.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files/pdf_preview_single.pdf")),
      filename: "preview.pdf", content_type: "application/pdf")

    visit student_login_path
    select "1年", from: "学年"
    select "1組", from: "クラス番号"
    select "1番", from: "出席番号"
    fill_in "学校コード", with: "PDFSYS"
    fill_in "パスワード", with: "password123"
    click_button "ログイン"
    expect(page).to have_current_path(student_assignments_path)
  end

  after do
    @browser_script_ids&.each do |identifier|
      page.driver.browser.execute_cdp("Page.removeScriptToEvaluateOnNewDocument", identifier: identifier)
    end
  end

  it "retains saved and unsaved ink when password revocation rejects a real draft request" do
    previous_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(page).to have_css('meta[name="csrf-token"]', visible: :all)
    ink_drag(0.1, 0.1, 0.2, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    saved = AnswerDraft.find_by!(assignment: @assignment).attributes
    page.execute_script(<<~JS)
      const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      editor.draft.delay=0;
      const original=editor.draft.request;
      editor.draft.request=async (url,options)=>{
        const response=await original(url,options);
        if(options.method==='PUT') window.revokedDraftStatus=response.status;
        return response;
      };
    JS
    student = Student.find(saved.fetch("student_id"))
    student.update!(password: "65820473")
    ink_drag(0.3, 0.1, 0.4, 0.1)
    expect(page).to have_text("ログインの有効期限が切れました", wait: 10)
    expect(page.evaluate_script("window.revokedDraftStatus")).to eq(401)
    expect(page).to have_current_path(student_assignment_pdf_preview_path(@assignment))
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(ink_alpha(0.35, 0.1)).to be > 0
    expect(page.evaluate_script(<<~JS)).to eq([ true, true, 2 ])
      (()=>{const e=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        return [e.draft.dirty,e.draft.blocked,e.pageStates[0].ink.pages.get(1).length];})()
    JS
    expect(AnswerDraft.find(saved.fetch("id")).attributes).to eq(saved)
    expect(Submission.where(assignment: @assignment)).to be_empty
    expect(page).to have_button("提出する", disabled: true)
  ensure
    ActionController::Base.allow_forgery_protection = previous_protection
  end

  it "resumes the same student's unsaved ink after a separate-tab login and submits once" do
    previous_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    ink_drag(0.1, 0.1, 0.2, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    saved_version = AnswerDraft.find_by!(assignment: @assignment).lock_version
    student = Student.find_by!(classroom: @assignment.classrooms.sole, attendance_number: 1)
    student.update!(password: "65820473")
    page.execute_script(<<~JS)
      const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      editor.draft.delay=0;
    JS
    ink_drag(0.3, 0.1, 0.4, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="recovery"]', visible: true, wait: 10)
    expect(page.evaluate_script(<<~JS)).to eq([ true, true, 2 ])
      (()=>{const e=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        return [e.draft.dirty,e.draft.blocked,e.pageStates[0].ink.pages.get(1).length];})()
    JS

    login_tab = window_opened_by { click_link "別タブで再ログイン" }
    within_window login_tab do
      select "1年", from: "学年"
      select "1組", from: "クラス番号"
      select "1番", from: "出席番号"
      fill_in "学校コード", with: "PDFSYS"
      fill_in "パスワード", with: "65820473"
      click_button "ログイン"
      expect(page).to have_current_path(student_assignments_path)
    end
    page.execute_script(<<~JS)
      const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      const original=window.fetch.bind(window);
      let once=true;
      window.fetch=(url,options)=>{
        if(once && String(url)===editor.recoveryUrlValue){once=false;throw new TypeError('offline');}
        return original(url,options);
      };
    JS
    click_button "再開を確認"
    expect(page).to have_text("接続を確認して再度お試しください", wait: 10)
    expect(page).to have_css('[data-pdf-preview-target="recovery"]', visible: true)
    click_button "再開を確認"
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 15)
    expect(page).to have_css('[data-pdf-preview-target="recovery"]', visible: false)
    expect(AnswerDraft.find_by!(assignment: @assignment).lock_version).to be > saved_version
    expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].length).to eq(2)
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(ink_alpha(0.35, 0.1)).to be > 0

    jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == AnswerReadingJob }
    click_button "提出する"
    expect(page).to have_current_path(student_assignment_path(@assignment), wait: 30)
    expect(Submission.where(assignment: @assignment).count).to eq(1)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == AnswerReadingJob }).to eq(jobs_before + 1)
  ensure
    ActionController::Base.allow_forgery_protection = previous_protection
  end

  it "blocks recovery when another tab changed the saved draft version" do
    previous_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    ink_drag(0.1, 0.1, 0.2, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    student = Student.find_by!(classroom: @assignment.classrooms.sole, attendance_number: 1)
    student.update!(password: "65820473")
    page.execute_script(<<~JS)
      const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      editor.draft.delay=0;
    JS
    ink_drag(0.3, 0.1, 0.4, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="recovery"]', visible: true, wait: 10)
    draft = AnswerDraft.find_by!(student: student, assignment: @assignment)
    changed = draft.page_data.deep_dup
    changed.first.fetch("operations").first["points"] = [ [ 50, 60 ] ]
    draft.update!(page_data: changed)
    snapshot = draft.reload.attributes
    login_tab = window_opened_by { click_link "別タブで再ログイン" }
    within_window login_tab do
      select "1年", from: "学年"
      select "1組", from: "クラス番号"
      select "1番", from: "出席番号"
      fill_in "学校コード", with: "PDFSYS"
      fill_in "パスワード", with: "65820473"
      click_button "ログイン"
      expect(page).to have_current_path(student_assignments_path)
    end
    click_button "再開を確認"
    expect(page).to have_text("下書き・提出状態が一致しません", wait: 10)
    expect(page).to have_button("提出する", disabled: true)
    expect(ink_alpha(0.35, 0.1)).to be > 0
    expect(draft.reload.attributes).to eq(snapshot)
  ensure
    ActionController::Base.allow_forgery_protection = previous_protection
  end

  it "keeps a stale answer stopped after another student logs in on the shared browser" do
    previous_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    student = Student.find_by!(classroom: @assignment.classrooms.sole, attendance_number: 1)
    other = Student.create!(classroom: student.classroom, attendance_number: 2, password: "password123")
    student.update!(password: "65820473")
    page.execute_script(<<~JS)
      const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      editor.draft.delay=0;
    JS
    ink_drag(0.1, 0.1, 0.2, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="recovery"]', visible: true, wait: 10)
    login_tab = window_opened_by { click_link "別タブで再ログイン" }
    within_window login_tab do
      select "1年", from: "学年"
      select "1組", from: "クラス番号"
      select "2番", from: "出席番号"
      fill_in "学校コード", with: "PDFSYS"
      fill_in "パスワード", with: "password123"
      click_button "ログイン"
      expect(page).to have_current_path(student_assignments_path)
    end
    click_button "再開を確認"
    expect(page).to have_text("生徒・クラス・教材・下書き・提出状態が一致しません", wait: 10)
    expect(page).to have_css('[data-pdf-preview-target="recovery"]', visible: true)
    expect(page).to have_button("提出する", disabled: true)
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(AnswerDraft.where(student: other, assignment: @assignment)).to be_empty
    expect(Submission.where(student: other, assignment: @assignment)).to be_empty
  ensure
    ActionController::Base.allow_forgery_protection = previous_protection
  end

  it "reuses the same PDF and submission token after a rejected upload and submits once" do
    previous_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    ink_drag(0.1, 0.1, 0.2, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    page.execute_script(<<~JS)
      const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      const original=window.fetch.bind(window);
      window.recoveryOriginalFetch=original;
      window.fetch=(url,options={})=> options.method==='POST' && String(url)===editor.submissionUrlValue
        ? new Promise(resolve=>window.releaseRecoveryUpload=()=>resolve(original(url,options).then(response=>{
          window.recoveryUploadStatus=response.status;return response;
        }))) : original(url,options);
      window.recoveryPdf=()=>{const attempt=editor.submissionAttempt;return attempt && [attempt.token,attempt.revision,Array.from(attempt.bytes)];};
    JS
    click_button "提出する"
    Timeout.timeout(15) { sleep 0.05 until page.evaluate_script("typeof window.releaseRecoveryUpload==='function'") }
    pdf = page.evaluate_script("window.recoveryPdf()")
    student = Student.find_by!(classroom: @assignment.classrooms.sole, attendance_number: 1)
    student.update!(password: "65820473")
    page.execute_script("window.releaseRecoveryUpload()")
    expect(page).to have_css('[data-pdf-preview-target="recovery"]', visible: true, wait: 10)
    expect(page.evaluate_script("window.recoveryUploadStatus")).to eq(401)
    expect(page.evaluate_script("window.recoveryPdf()")).to eq(pdf)
    login_tab = window_opened_by { click_link "別タブで再ログイン" }
    within_window login_tab do
      select "1年", from: "学年"
      select "1組", from: "クラス番号"
      select "1番", from: "出席番号"
      fill_in "学校コード", with: "PDFSYS"
      fill_in "パスワード", with: "65820473"
      click_button "ログイン"
      expect(page).to have_current_path(student_assignments_path)
    end
    click_button "再開を確認"
    expect(page).to have_css('[data-pdf-preview-target="recovery"]', visible: false, wait: 10)
    expect(page.evaluate_script("window.recoveryPdf()")).to eq(pdf)
    page.execute_script("window.fetch=window.recoveryOriginalFetch")
    click_button "提出する"
    expect(page).to have_current_path(student_assignment_path(@assignment), wait: 30)
    expect(Submission.where(assignment: @assignment).count).to eq(1)
    expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].length).to eq(1)
  ensure
    ActionController::Base.allow_forgery_protection = previous_protection
  end

  it "recognizes its own completed submission after the old session expires" do
    previous_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    ink_drag(0.1, 0.1, 0.2, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    page.execute_script(<<~JS)
      const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      const original=window.fetch.bind(window);
      window.fetch=(url,options={})=> options.method==='POST' && String(url)===editor.submissionUrlValue
        ? original(url,options).then(response=>new Promise(resolve=>{
          window.committedUploadStatus=response.status;
          window.finishCommittedUpload=()=>resolve(new Response(null,{status:401}));
        })) : original(url,options);
    JS
    click_button "提出する"
    Timeout.timeout(15) { sleep 0.05 until page.evaluate_script("window.committedUploadStatus===200") }
    expect(Submission.where(assignment: @assignment).count).to eq(1)
    student = Student.find_by!(classroom: @assignment.classrooms.sole, attendance_number: 1)
    student.update!(password: "65820473")
    page.execute_script("window.finishCommittedUpload()")
    expect(page).to have_css('[data-pdf-preview-target="recovery"]', visible: true, wait: 10)
    login_tab = window_opened_by { click_link "別タブで再ログイン" }
    within_window login_tab do
      select "1年", from: "学年"
      select "1組", from: "クラス番号"
      select "1番", from: "出席番号"
      fill_in "学校コード", with: "PDFSYS"
      fill_in "パスワード", with: "65820473"
      click_button "ログイン"
      expect(page).to have_current_path(student_assignments_path)
    end
    click_button "再開を確認"
    expect(page).to have_current_path(student_assignment_path(@assignment), wait: 30)
    expect(Submission.where(assignment: @assignment).count).to eq(1)
  ensure
    ActionController::Base.allow_forgery_protection = previous_protection
  end

  it "retains the generated PDF and ink when revocation rejects submission before authentication" do
    previous_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(page).to have_css('meta[name="csrf-token"]', visible: :all)
    page.execute_script(<<~JS)
      const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      editor.draft.delay=60_000;
      const original=window.fetch.bind(window);
      window.fetch=(url,options={})=> options.method==='POST' && String(url)===editor.submissionUrlValue
        ? new Promise(resolve=>window.releaseRevokedSubmission=()=>resolve(original(url,options).then(response=>{
          window.revokedSubmissionStatus=response.status;return response;
        }))) : original(url,options);
      window.pendingPdf=()=>{const a=editor.submissionAttempt;return a && [a.token,a.revision,Array.from(a.bytes)];};
    JS
    ink_drag(0.1, 0.1, 0.2, 0.1)
    click_button "提出する"
    Timeout.timeout(15) { sleep 0.05 until page.evaluate_script("typeof window.releaseRevokedSubmission==='function'") }
    pdf = page.evaluate_script("window.pendingPdf()")
    student = Student.joins(:classroom).find_by!(classrooms: { id: @assignment.classrooms.sole.id }, attendance_number: 1)
    student.update!(password: "65820473")
    page.execute_script("window.releaseRevokedSubmission()")
    expect(page).to have_text("ログインの有効期限が切れました", wait: 10)
    expect(page.evaluate_script("window.revokedSubmissionStatus")).to eq(401)
    expect(page.evaluate_script("window.pendingPdf()")).to eq(pdf)
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(page).to have_current_path(student_assignment_pdf_preview_path(@assignment))
    expect(Submission.where(assignment: @assignment)).to be_empty
    expect(AnswerDraft.where(assignment: @assignment)).to be_empty
    expect(page).to have_button("提出する", disabled: true)
  ensure
    ActionController::Base.allow_forgery_protection = previous_protection
  end

  it "saves with a small acknowledgment and restores every original coordinate" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    page.execute_script(<<~JS)
      const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      const request=editor.draft.request;
      editor.draft.request=async (url,options)=>{
        const response=await request(url,options);
        if(options.method==='PUT') window.draftAcknowledgment={
          requested:options.headers['X-Draft-Response'],request:JSON.parse(options.body),bytes:(await response.clone().text()).length,
          body:await response.clone().json()};
        return response;
      };
    JS
    ink_drag(0.1, 0.1, 0.4, 0.1)
    click_button "消しゴム"
    ink_drag(0.25, 0.08, 0.25, 0.12)
    click_button "ペン"
    ink_drag(0.3, 0.15, 0.35, 0.15)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 15)
    acknowledgment = page.evaluate_script("window.draftAcknowledgment")
    expect(acknowledgment.fetch("requested")).to eq("acknowledgment")
    expect(acknowledgment.fetch("bytes")).to be < 200
    expect(acknowledgment.fetch("body").fetch("draft").keys.sort).to eq(%w[updated_at version])
    ink_drag(0.45, 0.15, 0.5, 0.15)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 15)
    appended = page.evaluate_script("window.draftAcknowledgment.request")
    expect(appended).not_to have_key("draft_data")
    expect(appended.fetch("append_data").fetch("pages").first.fetch("operations").length).to eq(1)
    before = page.evaluate_script(<<~JS)
      window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview').draft.read().pages
    JS
    expect(AnswerDraft.find_by!(assignment: @assignment).page_data).to eq(before)
    page.refresh
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    after = page.evaluate_script(<<~JS)
      window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview').draft.read().pages
    JS
    expect(after).to eq(before)
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(ink_alpha(0.25, 0.1)).to eq(0)
  end

  it "requests a native leave confirmation before browser Back can discard an unsaved stroke" do
    click_link "表示試験"
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    page.execute_script(<<~JS)
      const editor = window.Stimulus.getControllerForElementAndIdentifier(
        document.querySelector('[data-controller="pdf-preview"]'), 'pdf-preview');
      editor.draft.delay = 60_000;
    JS
    ink_drag(0.1, 0.2, 0.5, 0.2)
    expect(page.evaluate_script(<<~JS)).to be(true)
      window.Stimulus.getControllerForElementAndIdentifier(
        document.querySelector('[data-controller="pdf-preview"]'), 'pdf-preview').draft.dirty
    JS
    expect(AnswerDraft.where(assignment: @assignment)).to be_empty

    expect(page.evaluate_script("document.querySelector('meta[name=turbo-visit-control]')?.content")).to eq("reload")
    expect(page.evaluate_script("document.documentElement.dataset.turbo")).to eq("false")
    expect(page.evaluate_script("(() => { const event = new Event('beforeunload', { cancelable: true }); window.dispatchEvent(event); return event.defaultPrevented })()")).to be(true)
    expect(page).to have_current_path(student_assignment_pdf_preview_path(@assignment))
    expect(ink_alpha(0.3, 0.2)).to be > 0
    record_leave_guard
    page.go_back
    expect(page).to have_current_path(student_assignments_path)
    # WebDriver does not expose a dismissible beforeunload dialog in headless Chrome.
    # Record the browser event after the application handler to verify the guard ran.
    expect(leave_guard_value).to eq("true")
    expect(AnswerDraft.where(assignment: @assignment)).to be_empty
  end

  it "moves Back and Forward without a warning once autosave finishes and restores the ink" do
    click_link "表示試験"
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    ink_drag(0.1, 0.2, 0.5, 0.2)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].size).to eq(1)
    record_leave_guard
    page.go_back
    expect(page).to have_current_path(student_assignments_path)
    expect(leave_guard_value).to eq("false")
    page.go_forward
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(ink_alpha(0.3, 0.2)).to be > 0
  end

  it "requests leave confirmation for an unsaved stroke on the QuickFlow link and browser Forward" do
    click_link "表示試験"
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    page.execute_script("window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller=pdf-preview]'), 'pdf-preview').draft.delay = 60_000")
    ink_drag(0.1, 0.2, 0.5, 0.2)
    record_leave_guard
    click_link "QuickFlow"
    expect(page).to have_current_path(student_assignments_path)
    expect(leave_guard_value).to eq("true")

    page.go_back
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    page.execute_script("window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller=pdf-preview]'), 'pdf-preview').draft.delay = 60_000")
    page.execute_script("window.scrollTo(0, 0)")
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    ink_drag(0.1, 0.2, 0.5, 0.2)
    expect(page.evaluate_script("window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller=pdf-preview]'), 'pdf-preview').draft.dirty")).to be(true)
    record_leave_guard
    page.go_forward
    expect(page).to have_current_path(student_assignments_path)
    expect(leave_guard_value).to eq("true")
  end

  it "requests leave confirmation on reload after autosave fails offline" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    page.execute_script(<<~JS)
      const editor = window.Stimulus.getControllerForElementAndIdentifier(
        document.querySelector('[data-controller="pdf-preview"]'), 'pdf-preview');
      editor.draft.delay = 0;
      editor.draft.request = async () => { throw new TypeError('offline') };
    JS
    ink_drag(0.1, 0.2, 0.5, 0.2)
    expect(page).to have_text("保存できませんでした", wait: 8)
    expect(ink_alpha(0.3, 0.2)).to be > 0
    record_leave_guard
    page.refresh
    expect(leave_guard_value).to eq("true")
    expect(AnswerDraft.where(assignment: @assignment)).to be_empty
  end

  it "requests leave confirmation while the draft save is still in flight" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    page.execute_script(<<~JS)
      const editor = window.Stimulus.getControllerForElementAndIdentifier(
        document.querySelector('[data-controller="pdf-preview"]'), 'pdf-preview');
      editor.draft.delay = 0;
      editor.draft.request = (url, options) => options.method === 'PUT'
        ? new Promise(() => {}) : window.fetch(url, options);
    JS
    ink_drag(0.1, 0.2, 0.5, 0.2)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存中…", wait: 8)
    record_leave_guard
    page.go_back
    expect(leave_guard_value).to eq("true")
    expect(AnswerDraft.where(assignment: @assignment)).to be_empty
  end

  it "renders page one with a real local module worker and preserves its aspect ratio after resizing" do
    install_browser_script(<<~JS)
      window.pdfPreviewWorkers = [];
      const NativeWorker = window.Worker;
      window.Worker = class extends NativeWorker {
        constructor(url, options) {
          super(url, options);
          window.pdfPreviewWorkers.push({ url: String(url), type: options.type });
        }
      };
    JS
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(page).to have_css("canvas", count: 2)
    worker = page.evaluate_script("window.pdfPreviewWorkers")
    expect(worker.size).to eq(1)
    expect(worker.first).to eq("url" => "/vendor/pdfjs/6.4.299/pdf.worker.min.mjs", "type" => "module")
    expect(page.driver.browser.logs.get(:browser).map(&:message).join).not_to include("fake worker")

    assert_canvas
    page.current_window.resize_to(800, 900)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    # Wait for the debounced backing-store resize, not just CSS scaling.
    expect(page).to have_css("canvas", visible: true)
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script(<<~JS)
        (() => { const c = document.querySelector('canvas');
          return Math.abs(c.width - c.getBoundingClientRect().width * Math.min(devicePixelRatio, 2)) <= 1; })()
      JS
    end
    assert_canvas
    resources = page.evaluate_script("performance.getEntriesByType('resource').map(r => r.name)")
    expect(resources).to all(start_with(URI.parse(page.current_url).then { |uri| "#{uri.scheme}://#{uri.host}:#{uri.port}/" }))
    expect(Submission.count).to eq(0)
  end

  it "shows only the quiz title, hides routine notices and fits the wide submit button on narrow screens" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(page).to have_no_css("footer, body.app-shell", visible: :all)
    expect(page).to have_css("h1", exact_text: @assignment.title)
    expect(page).to have_no_button("確認用PDFをダウンロード")
    expect(page).to have_no_text("確認用のダウンロードです。")
    expect(page).to have_no_css('[data-pdf-preview-target="submitStatus"]', visible: true)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "未保存")
    ink_drag(0.1, 0.2, 0.4, 0.2)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存済み", wait: 10)
    expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].length).to eq(1)
    [ 320, 390, 768, 1280 ].each do |width|
      page.current_window.resize_to(width, 900)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
        width: width, height: 900, deviceScaleFactor: 1, mobile: false)
      expect(page.evaluate_script("innerWidth")).to eq(width)
      layout = page.evaluate_script(<<~JS)
        (()=>{const button=document.querySelector('[data-pdf-preview-target="submit"]');
          const notice=document.querySelector('[data-pdf-preview-target="draftStatus"]');
          const r=button.getBoundingClientRect(), n=notice.getBoundingClientRect();
          const style=getComputedStyle(button);
          return {width:r.width,height:r.height,font:style.fontSize,fits:r.right<=innerWidth&&r.left>=0,
            clipped:getComputedStyle(notice).clipPath,noticeHeight:n.height,
            overflow:document.documentElement.scrollWidth>innerWidth};})()
      JS
      expect(layout["width"]).to be <= 480
      expect(layout["width"]).to be > 200
      expect(layout["height"]).to be >= 52
      expect(layout["font"]).to eq("18px")
      expect(layout["fits"]).to be(true)
      expect(layout["overflow"]).to be(false)
      expect(layout["clipped"]).to eq("inset(50%)")
      expect(layout["noticeHeight"]).to eq(1)
    end
    page.refresh
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(ink_alpha(0.2, 0.2)).to be > 0
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1280, 900)
  end

  it "shows an error instead of a blank canvas when the PDF is corrupt" do
    @assignment.material_file.attach(io: StringIO.new("%PDF-1.7\ninvalid"),
      filename: "broken.pdf", content_type: "application/pdf")
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('[role="alert"]', text: "問題を表示できませんでした", wait: 20)
    expect(page).to have_no_css("canvas", visible: true)
  end

  it "shows an error when the authenticated material endpoint returns 404" do
    @assignment.material_file.detach
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('[role="alert"]', text: "問題を表示できませんでした", wait: 20)
    expect(page).to have_no_css("canvas", visible: true)
  end

  it "shows an error when the real worker fails to load" do
    # A new URL avoids the successful worker module cached by the preceding test.
    # This still creates a real Worker; only its URL is changed to a local 404.
    install_browser_script(<<~JS)
      const WorkingWorker = window.Worker;
      window.Worker = class extends WorkingWorker {
        constructor(url, options) {
          super('/vendor/pdfjs/6.4.299/missing-worker.mjs', options);
        }
      };
    JS
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('[role="alert"]', text: "問題を表示できませんでした", wait: 20)
    expect(page).to have_no_css("canvas", visible: true)
  end

  it "draws separate mouse strokes and a dot on a transparent layer and keeps them aligned after resize" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    overlay = find('[data-pdf-preview-target="ink"]')
    bounds = page.evaluate_script(<<~JS)
      (() => {
        const pdf = document.querySelector('[data-pdf-preview-target="canvas"]').getBoundingClientRect();
        const ink = document.querySelector('[data-pdf-preview-target="ink"]').getBoundingClientRect();
        return {aligned: ['x','y','width','height'].every(k => Math.abs(pdf[k]-ink[k]) < 0.1),
          x: ink.x, y: ink.y, width: ink.width, height: ink.height};
      })()
    JS
    expect(bounds["aligned"]).to be(true)
    y = (bounds["y"] + bounds["height"] * 0.1).round
    actions = page.driver.browser.action
    [ [ 0.1, 0.2 ], [ 0.35, 0.45 ] ].each do |start_x, end_x|
      actions.move_to_location((bounds["x"] + bounds["width"] * start_x).round, y)
        .pointer_down(:left).move_to_location((bounds["x"] + bounds["width"] * end_x).round, y)
        .pointer_up(:left)
    end
    actions.move_to_location((bounds["x"] + bounds["width"] * 0.7).round, y).click.perform
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(ink_alpha(0.4, 0.1)).to be > 0
    expect(ink_alpha(0.7, 0.1)).to be > 0
    expect(ink_alpha(0.275, 0.1)).to eq(0)
    expect(ink_alpha(0.9, 0.1)).to eq(0)
    expect(page.evaluate_script("window.getSelection().toString()")).to eq("")
    expect(overlay["class"]).to include("pdf-preview-ink")

    page.current_window.resize_to(800, 900)
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script(<<~JS)
        (() => { const c = document.querySelector('[data-pdf-preview-target="ink"]');
          return !c.hidden && Math.abs(c.width-c.getBoundingClientRect().width*Math.min(devicePixelRatio,2)) <= 1; })()
      JS
    end
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(ink_alpha(0.7, 0.1)).to be > 0
    expect(ink_alpha(0.275, 0.1)).to eq(0)
    # The PDF itself remains intact and its original black square is still present.
    assert_canvas
    page.driver.browser.action.scroll_by(0, 150).perform
    Timeout.timeout(5) { sleep 0.05 until page.evaluate_script("window.scrollY") > 0 }
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存済み", wait: 10)
    page.refresh
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(ink_alpha(0.15, 0.1)).to be > 0
  end

  it "partially erases only ink and replays pen/eraser/pen after resize and high-DPI rendering" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(find_button("ペン")["aria-pressed"]).to eq("true")
    expect(find_button("消しゴム")["aria-pressed"]).to eq("false")
    original_pdf = find('[data-pdf-preview-target="canvas"]').evaluate_script("this.toDataURL()")
    ink_drag(0.1, 0.1, 0.5, 0.1)
    ink_drag(0.1, 0.12, 0.5, 0.12)
    ink_drag(0.8, 0.1, 0.8, 0.1)
    expect(ink_alpha(0.2, 0.1)).to be > 0

    # Native buttons also activate via keyboard.
    find_button("消しゴム").send_keys(:space)
    click_button "小"
    expect(find_button("消しゴム")["aria-pressed"]).to eq("true")
    expect(find_button("ペン")["aria-pressed"]).to eq("false")
    expect(find('[data-pdf-preview-target="ink"]').evaluate_script("this.style.cursor")).to eq("none")
    ink_drag(0.2, 0.1, 0.2, 0.1)
    ink_drag(0.4, 0.09, 0.4, 0.11)
    expect(ink_alpha(0.2, 0.1)).to eq(0)
    expect(ink_alpha(0.4, 0.1)).to eq(0)
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(ink_alpha(0.3, 0.1)).to be > 0
    expect(ink_alpha(0.45, 0.1)).to be > 0
    expect(ink_alpha(0.4, 0.12)).to be > 0
    expect(ink_alpha(0.8, 0.1)).to be > 0
    expect(find('[data-pdf-preview-target="canvas"]').evaluate_script("this.toDataURL()")).to eq(original_pdf)

    find_button("ペン").send_keys(:enter)
    expect(find_button("ペン")["aria-pressed"]).to eq("true")
    ink_drag(0.2, 0.1, 0.2, 0.1)
    expect(ink_alpha(0.2, 0.1)).to be > 0
    begin
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 800, height: 900,
        deviceScaleFactor: 2, mobile: false)
      Timeout.timeout(5) do
        sleep 0.05 until page.evaluate_script(<<~JS)
          (() => { const c = document.querySelector('[data-pdf-preview-target="ink"]');
            return !c.hidden && devicePixelRatio === 2 && Math.abs(c.width-c.getBoundingClientRect().width*2) <= 1; })()
        JS
      end
      expect(ink_alpha(0.2, 0.1)).to be > 0
      expect(ink_alpha(0.4, 0.1)).to eq(0)
      expect(ink_alpha(0.45, 0.1)).to be > 0
      expect(ink_alpha(0.4, 0.12)).to be > 0
      expect(ink_alpha(0.8, 0.1)).to be > 0
      assert_canvas
      click_button "消しゴム"
    click_button "小"
      page.driver.browser.action.scroll_by(0, 150).perform
      Timeout.timeout(5) { sleep 0.05 until page.evaluate_script("window.scrollY") > 0 }
      expect(ink_alpha(0.4, 0.1)).to eq(0)
      expect(ink_alpha(0.2, 0.1)).to be > 0
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end

  def ink_drag(x1, y1, x2, y2, number = nil)
    scroll_page(number) if number
    prefix = number ? "[data-page-number='#{number}'] " : ""
    rect = page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector("#{prefix}[data-pdf-preview-target='ink']").getBoundingClientRect();
        return {x:r.x, y:r.y, width:r.width, height:r.height}; })()
    JS
    page.driver.browser.action.move_to_location((rect["x"] + rect["width"] * x1).round, (rect["y"] + rect["height"] * y1).round)
      .pointer_down(:left)
      .move_to_location((rect["x"] + rect["width"] * x2).round, (rect["y"] + rect["height"] * y2).round)
      .pointer_up(:left).perform
  end

  def ink_alpha(x, y, number = nil)
    scroll_page(number) if number
    prefix = number ? "[data-page-number='#{number}'] " : ""
    page.evaluate_script(<<~JS)
      (() => { const c = document.querySelector("#{prefix}[data-pdf-preview-target='ink']");
        return c.getContext('2d').getImageData(Math.round(c.width*#{x}), Math.round(c.height*#{y}), 1, 1).data[3]; })()
    JS
  end

  it "keeps three differently sized/rotated pages independent through erasing, scrolling, resizing and DPR changes" do
    attach_preview("pdf_preview_three.pdf")
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(all(".pdf-preview-sheet").map { |sheet| sheet["data-page-number"] }).to eq(%w[1 2 3])
    expect(page).to have_css("canvas", count: 6, visible: :all)
    ratios = page.evaluate_script("Array.from(document.querySelectorAll('.pdf-preview-page')).map(p => p.clientWidth/p.clientHeight)")
    [ 2.0 / 3, 1.5, 1.5 ].each_with_index { |ratio, i| expect(ratios[i]).to be_within(0.01).of(ratio) }
    colors = (1..3).map do |number|
      scroll_page(number)
      find("[data-page-number='#{number}'] [data-pdf-preview-target='canvas']").evaluate_script("Array.from(this.getContext('2d').getImageData(Math.floor(this.width/2),Math.floor(this.height/2),1,1).data)")
    end
    expect(colors).to eq([ [ 0, 0, 0, 255 ], [ 255, 0, 0, 255 ], [ 0, 0, 255, 255 ] ])

    (1..3).each do |number|
      scroll_page(number)
      expect(ink_alpha(0.2, 0.2, number)).to eq(0)
      ink_drag(0.1, 0.2, 0.6, 0.2, number)
      ink_drag(0.8, 0.2, 0.8, 0.2, number)
      expect(ink_alpha(0.2, 0.2, number)).to be > 0
    end
    # Page 2's operations never appear on pages 1 or 3.
    scroll_page(2)
    ink_drag(0.75, 0.3, 0.75, 0.3, 2)
    expect(ink_alpha(0.75, 0.3, 1)).to eq(0)
    expect(ink_alpha(0.75, 0.3, 3)).to eq(0)
    scroll_page(2)
    original = find('[data-page-number="2"] [data-pdf-preview-target="canvas"]').evaluate_script("this.toDataURL()")
    click_button "消しゴム"
    click_button "小"
    ink_drag(0.3, 0.2, 0.3, 0.2, 2)
    ink_drag(0.45, 0.18, 0.45, 0.22, 2)
    expect(ink_alpha(0.3, 0.2, 2)).to eq(0)
    expect(ink_alpha(0.45, 0.2, 2)).to eq(0)
    expect(ink_alpha(0.2, 0.2, 1)).to be > 0
    expect(ink_alpha(0.3, 0.2, 3)).to be > 0
    scroll_page(2)
    expect(find('[data-page-number="2"] [data-pdf-preview-target="canvas"]').evaluate_script("this.toDataURL()")).to eq(original)
    click_button "ペン"
    ink_drag(0.3, 0.2, 0.3, 0.2, 2)
    expect(ink_alpha(0.3, 0.2, 2)).to be > 0

    begin
      page.current_window.resize_to(1000, 900)
      page.current_window.resize_to(900, 900)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 800, height: 900, deviceScaleFactor: 2, mobile: false)
      Timeout.timeout(10) do
        sleep 0.05 until page.evaluate_script(<<~JS)
          Array.from(document.querySelectorAll('[data-pdf-preview-target="ink"]')).some(c =>
            !c.hidden && Math.abs(c.width-c.getBoundingClientRect().width*2) <= 1)
        JS
      end
      (1..3).each do |number|
        scroll_page(number)
        expect(ink_alpha(0.2, 0.2, number)).to be > 0
        expect(ink_alpha(0.8, 0.2, number)).to be > 0
      end
      expect(ink_alpha(0.45, 0.2, 2)).to eq(0)
      expect(ink_alpha(0.3, 0.2, 2)).to be > 0
      expect(ink_alpha(0.75, 0.3, 1)).to eq(0)
      expect(ink_alpha(0.75, 0.3, 2)).to be > 0
      expect(find_button("ペン")["aria-pressed"]).to eq("true")
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end

  it "ends captured input at a page boundary without drawing on the next page" do
    page.current_window.resize_to(800, 1100)
    attach_preview("pdf_preview_three.pdf")
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    scroll_page(2)
    rect = find('[data-page-number="2"] [data-pdf-preview-target="ink"]').evaluate_script("this.getBoundingClientRect().toJSON()")
    x = (rect["x"] + rect["width"] * 0.2).round
    y = (rect["bottom"] - 20).round
    page.driver.browser.action.move_to_location(x, y).pointer_down(:left)
      .move_to_location(x, (rect["bottom"] + 40).round).pointer_up(:left).perform
    expect(ink_alpha(0.2, 0.05, 3)).to eq(0)
    scroll_page(3)
    ink_drag(0.2, 0.2, 0.2, 0.2, 3)
    expect(ink_alpha(0.2, 0.2, 3)).to be > 0
    scroll_page(2)
    expect(ink_alpha(0.2, 0.2, 2)).to eq(0)
  end

  it "renders ten pages sequentially with a bounded total bitmap allocation and can leave the screen" do
    attach_preview("pdf_preview_ten.pdf")
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(page).to have_css("canvas", count: 20, visible: :all)
    pixels = page.evaluate_script(<<~JS)
      (() => {
        const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        return editor.pageStates.reduce((sum,s)=>sum+s.canvas.width*s.canvas.height+s.inkCanvas.width*s.inkCanvas.height+s.ink.cache.width*s.ink.cache.height,0);
      })()
    JS
    expect(pixels).to be <= 32_100_000
    scroll_page(10)
    ink_drag(0.2, 0.2, 0.2, 0.2, 10)
    expect(ink_alpha(0.2, 0.2, 10)).to be > 0
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存済み", wait: 10)
    visit student_assignment_path(@assignment)
    expect(page).to have_current_path(student_assignment_path(@assignment))
    expect(page).to have_link("PDFに解答する")
    expect(page).to have_css('details input[type="file"]', visible: :all)
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(ink_alpha(0.2, 0.2, 10)).to be > 0
  end

  def scroll_page(number)
    find("[data-page-number='#{number}']").execute_script("this.scrollIntoView({block:'start'})")
    expect(page).to have_css("[data-page-number='#{number}'] [data-pdf-preview-target='ink']", visible: true, wait: 15)
    page.evaluate_async_script("const done=arguments[arguments.length-1]; requestAnimationFrame(()=>requestAnimationFrame(done))")
  end

  it "offers three erase widths, remembers selection, and restores each recorded footprint" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(page).to have_no_css('[data-pdf-preview-target="sizes"]', visible: true)
    ink_drag(0.1, 0.2, 0.9, 0.2)
    original = find('[data-pdf-preview-target="canvas"]').evaluate_script("this.toDataURL()")
    click_button "消しゴム"
    expect(find_button("中")["aria-pressed"]).to eq("true")
    expect(page).to have_css('[data-pdf-preview-target="size"]', count: 3)
    [ [ "小", 0.2, 4 ], [ "中", 0.4, 8 ], [ "大", 0.6, 18 ] ].each do |label, x, width|
      find_button(label).send_keys(:space)
      expect(find_button(label)["aria-pressed"]).to eq("true")
      ink_drag(x, 0.2, x, 0.2)
      expect(ink_alpha(x, 0.2)).to eq(0)
      geometry = page.evaluate_script(<<~JS)
        (() => { const c = document.querySelector('[data-pdf-preview-target="ink"]');
          return {pageWidth:c.getBoundingClientRect().width,
            cursor:document.querySelector('.pdf-preview-eraser-cursor').getBoundingClientRect().width}; })()
      JS
      expect(geometry["cursor"]).to be_within(0.5).of(geometry["pageWidth"] * width / 200.0)
    end
    expect(ink_alpha(0.215, 0.2)).to be > 0 # Outside small radius.
    expect(ink_alpha(0.415, 0.2)).to eq(0) # Inside medium radius.
    expect(ink_alpha(0.425, 0.2)).to be > 0
    expect(ink_alpha(0.625, 0.2)).to eq(0) # Inside large radius.
    expect(ink_alpha(0.65, 0.2)).to be > 0
    expect(find('[data-pdf-preview-target="canvas"]').evaluate_script("this.toDataURL()")).to eq(original)
    click_button "ペン"
    expect(page).to have_no_css('[data-pdf-preview-target="sizes"]', visible: true)
    click_button "消しゴム"
    expect(find_button("大")["aria-pressed"]).to eq("true")
    click_button "小"
    page.current_window.resize_to(800, 900)
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script(<<~JS)
        (() => { const c = document.querySelector('[data-pdf-preview-target="ink"]');
          return !c.hidden && Math.abs(c.width-c.getBoundingClientRect().width*Math.min(devicePixelRatio,2)) <= 1; })()
      JS
    end
    expect(ink_alpha(0.215, 0.2)).to be > 0
    expect(ink_alpha(0.415, 0.2)).to eq(0)
    expect(ink_alpha(0.625, 0.2)).to eq(0)
  end

  it "restores all erase sizes after releasing offscreen canvases without moving page geometry" do
    attach_preview("pdf_preview_ten.pdf")
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    scroll_page(1)
    ink_drag(0.1, 0.2, 0.9, 0.2, 1)
    click_button "消しゴム"
    [ [ "小", 0.2 ], [ "中", 0.4 ], [ "大", 0.6 ] ].each do |label, x|
      click_button label
      ink_drag(x, 0.2, x, 0.2, 1)
    end
    saved = find('[data-page-number="1"] [data-pdf-preview-target="ink"]').evaluate_script("this.toDataURL()")
    positions = page.evaluate_script("Array.from(document.querySelectorAll('.pdf-preview-sheet')).map(s=>s.getBoundingClientRect().top+scrollY)")
    scroll_page(10)
    expect(find_button("大")["aria-pressed"]).to eq("true")
    Timeout.timeout(5) do
      sleep 0.05 until page.evaluate_script("document.querySelector('[data-page-number=\"1\"] canvas').width === 0")
    end
    click_button "ペン"
    ink_drag(0.1, 0.2, 0.9, 0.2, 10)
    click_button "消しゴム"
    ink_drag(0.6, 0.2, 0.6, 0.2, 10)
    expect(ink_alpha(0.625, 0.2, 10)).to eq(0)
    scroll_page(1)
    expect(find('[data-page-number="1"] [data-pdf-preview-target="ink"]').evaluate_script("this.toDataURL()")).to eq(saved)
    expect(page.evaluate_script("Array.from(document.querySelectorAll('.pdf-preview-sheet')).map(s=>s.getBoundingClientRect().top+scrollY)")).to eq(positions)
    before = page.evaluate_script("scrollY")
    sleep 0.2
    expect(page.evaluate_script("scrollY")).to eq(before)
  end

  it "measures one, three and ten page previews at the same viewport and DPR" do
    begin
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 800, height: 900, deviceScaleFactor: 2, mobile: false)
      [ [ "pdf_preview_single.pdf", 1 ], [ "pdf_preview_three.pdf", 3 ], [ "pdf_preview_ten.pdf", 10 ] ].each do |filename, count|
        attach_preview(filename)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        visit student_assignment_pdf_preview_path(@assignment)
        expect(page).to have_css('[data-page-number="1"] [data-pdf-preview-target="ink"]', visible: true, wait: 30)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        metrics = page.evaluate_script(<<~JS)
          (() => { const c = document.querySelector('canvas'); const r=c.getBoundingClientRect();
            const all=Array.from(document.querySelectorAll('canvas'));
            return {density:c.width/r.width, pixels:all.reduce((n,c)=>n+c.width*c.height,0),
              resident:all.filter(c=>c.width>0).length/2, total:#{count}}; })()
        JS
        expect(metrics["density"]).to be_within(0.01).of(2)
        expect(metrics["pixels"]).to be <= 32_100_000
        expect(metrics["resident"]).to be < count if count == 10
        puts "B2_METRIC #{metrics.merge("elapsed_seconds" => elapsed.round(3), "rgba_mb" => (metrics["pixels"] * 4 / 1_000_000.0).round(2)).to_json}"
      end
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    end
  end

  it "accepts touch size buttons and ignores two palm contacts while a pen is down" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    [ "消しゴム", "大" ].each do |label|
      rect = find_button(label).evaluate_script("this.getBoundingClientRect().toJSON()")
      action = page.driver.browser.action
      action.add_pointer_input(:touch, "size-touch")
      action.move_to_location((rect["x"] + rect["width"] / 2).round, (rect["y"] + rect["height"] / 2).round, device: "size-touch")
        .pointer_down(:left, device: "size-touch").pointer_up(:left, device: "size-touch").perform
    end
    expect(find_button("大")["aria-pressed"]).to eq("true")
    click_button "ペン"
    rect = find('[data-pdf-preview-target="ink"]').evaluate_script("this.getBoundingClientRect().toJSON()")
    x = (rect["x"] + rect["width"] * 0.2).round
    y = (rect["y"] + rect["height"] * 0.1).round
    pen = page.driver.browser.action
    pen.add_pointer_input(:pen, "held-pen")
    pen.move_to_location(x, y, device: "held-pen").pointer_down(:left, device: "held-pen").perform
    before = page.evaluate_script("scrollY")
    touch = page.driver.browser.action
    touch.add_pointer_input(:touch, "extra-touch")
    touch.move_to_location(x + 50, y + 20, device: "extra-touch").pointer_down(:left, device: "extra-touch").perform
    touch = page.driver.browser.action
    touch.add_pointer_input(:touch, "extra-palm")
    touch.move_to_location(x + 80, y + 30, device: "extra-palm").pointer_down(:left, device: "extra-palm")
      .move_to_location(x + 80, y + 10, device: "extra-palm").perform
    expect(page.evaluate_script("scrollY")).to eq(before)
    pen = page.driver.browser.action
    pen.add_pointer_input(:pen, "held-pen")
    pen.move_to_location((rect["x"] + rect["width"] * 0.3).round, y, device: "held-pen")
      .pointer_up(:left, device: "held-pen").perform
    %w[extra-touch extra-palm].each do |name|
      touch = page.driver.browser.action
      touch.add_pointer_input(:touch, name)
      touch.pointer_up(:left, device: name).perform
    end
    expect(ink_alpha(0.25, 0.1)).to be > 0
  ensure
    # A dedicated session keeps native multi-pointer state out of later examples.
    page.driver.quit
  end

  [ [ "pdf_preview_single.pdf", 1 ], [ "pdf_preview_three.pdf", 3 ], [ "pdf_preview_ten.pdf", 10 ] ].each do |filename, count|
    it "generates and reopens #{count} pages including offscreen ink, ordered erasing and preserved source vectors" do
      attach_preview(filename)
      if count == 3
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 1280, height: 900, deviceScaleFactor: 2, mobile: false)
      end
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      expect(page).not_to have_text("書いた内容は保存されません")
      expect(page).not_to have_text("ページを表示しています")
      expect(page).not_to have_css(".pdf-preview-page-number")
      expect(page).not_to have_link("小テストの詳細へ戻る")
      ink_drag(0.1, 0.15, 0.35, 0.15, 1)
      ink_drag(0.1, 0.15, 0.35, 0.15, count) if count > 1
      reading_jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == AnswerReadingJob }
      scroll_page(1)
      if count == 3
        page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 900, height: 900, deviceScaleFactor: 2, mobile: false)
        page.execute_script("document.body.style.zoom = '1.1'")
        expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      end
      generate_preview_pdf
      expect(page.evaluate_script("window.exportBlobs[0].type")).to eq("application/pdf")
      result = page.evaluate_async_script(<<~JS)
        const done = arguments[arguments.length - 1];
        (async () => {
          const c = window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'), 'pdf-preview');
          const {getDocument} = await import('pdfjs');
          const output = await getDocument({data: new Uint8Array(await window.exportBlobs[0].arrayBuffer()), worker:c.pdfWorker}).promise;
          const results = [];
          for (let n=1;n<=output.numPages;n++) {
            const p = await output.getPage(n), original = await c.pdf.getPage(n);
            const v=p.getViewport({scale:2}), before=original.getViewport({scale:2});
            const canvas=document.createElement('canvas'); canvas.width=v.width; canvas.height=v.height;
            const ctx=canvas.getContext('2d');
            await p.render({canvasContext:ctx,viewport:v}).promise;
            const pixel=(x,y)=>Array.from(ctx.getImageData(Math.round(v.width*x),Math.round(v.height*y),1,1).data);
            results.push({size:[v.width,v.height], originalSize:[before.width,before.height],
              ink:pixel(.22,.15), untouched:pixel(.8,.15), center:pixel(.5,.5),
              text:(await p.getTextContent()).items.map(i=>i.str), originalText:(await original.getTextContent()).items.map(i=>i.str)});
            canvas.width=canvas.height=0;
          }
          done({pages:results, count:output.numPages, bytes:window.exportBlobs[0].size,
            milliseconds:window.exportGenerationMs,
            reusedSource:window.sourceRequestCount===window.materialRequests(),
            localResources:performance.getEntriesByType('resource').every(r=>new URL(r.name).origin===location.origin),
            retained:window.exportSourceOperations===JSON.stringify(c.pageStates.map(s=>[...s.ink.pages.values()]))});
        })().catch(e=>done({error:String(e)}));
      JS
      expect(result["error"]).to be_nil
      expect(result["count"]).to eq(count)
      expect(result["retained"]).to be(true)
      expect(result["reusedSource"]).to be(true)
      expect(result["localResources"]).to be(true)
      result.fetch("pages").each_with_index do |item, index|
        expect(item["size"]).to eq(item["originalSize"])
        expect(item["text"]).to eq(item["originalText"])
        color = count == 3 ? [ [ 0, 0, 0 ], [ 255, 0, 0 ], [ 0, 0, 255 ] ][index] : [ 0, 0, 0 ]
        expect(item["center"].first(3)).to eq(color)
        expect(item["untouched"].first(3)).to eq([ 255, 255, 255 ])
        if index == 0 || index == count - 1
          expect(item["ink"].first(3).max).to be < 80
        else
          expect(item["ink"].first(3)).to eq([ 255, 255, 255 ])
        end
      end
      expect(Submission.where(assignment: @assignment)).to be_empty
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == AnswerReadingJob }).to eq(reading_jobs_before)
      puts "C_EXPORT_METRIC #{result.except("pages", "retained").to_json}"
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if count == 3
    end
  end

  it "keeps ink and the saved draft with accurate guidance when generated PDF validation fails" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    ink_drag(0.1, 0.1, 0.3, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    saved = AnswerDraft.find_by!(assignment: @assignment).attributes
    allow(PdfReadabilityValidator).to receive(:validate!).and_raise(PdfReadabilityValidator::InvalidPdf)

    click_button "提出する"

    expect(page).to have_text("PDFの内容を確認できませんでした", wait: 30)
    expect(page).to have_text("この画面を閉じず、先生に確認してください")
    expect(ink_alpha(0.2, 0.1)).to be > 0
    expect(AnswerDraft.find_by!(assignment: @assignment).attributes).to eq(saved)
    expect(Submission.where(assignment: @assignment)).to be_empty
  end

  it "retains ink after submission PDF generation fails and succeeds on retry" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    ink_drag(0.1, 0.1, 0.3, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    page.execute_script(<<~JS)
      window.nativeToBlob = HTMLCanvasElement.prototype.toBlob;
      HTMLCanvasElement.prototype.toBlob = function(callback) { callback(null); };
    JS
    click_button "提出する"
    expect(page).to have_text("提出できませんでした", wait: 30)
    expect(ink_alpha(0.2, 0.1)).to be > 0
    expect(page).to have_button("提出する", disabled: false)
    expect(Submission.where(assignment: @assignment)).to be_empty
    expect(AnswerDraft.find_by!(assignment: @assignment)).to be_persisted
    page.execute_script("HTMLCanvasElement.prototype.toBlob = window.nativeToBlob")
    click_button "提出する"
    expect(page).to have_current_path(student_assignment_path(@assignment), wait: 30)
    expect(Submission.find_by!(assignment: @assignment).answer_file).to be_attached
  end

  it "exports rotations, offset CropBoxes, all eraser widths, dots and rewritten ink independently of screen resolution" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    result = page.evaluate_async_script(<<~JS)
      const done=arguments[arguments.length-1];
      (async()=>{
        const {PDFDocument,degrees,rgb,StandardFonts}=await import('pdf-lib');
        const {generateAnswerPdf}=await import('pdf_export');
        const {getDocument}=await import('pdfjs');
        const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        const doc=await PDFDocument.create(), font=await doc.embedFont(StandardFonts.Helvetica);
        for(const rotation of [0,90,180,270]) {
          const p=doc.addPage([320,400]); p.setCropBox(20,30,240,300); p.setRotation(degrees(rotation));
          p.drawText('x^2 + 1/2 = 0.5',{x:40,y:300,size:12,font});
          p.drawRectangle({x:30,y:50,width:210,height:180,color:rgb(1,0,0)});
        }
        const source=await doc.save();
        const input=await getDocument({data:source.slice(),worker:c.pdfWorker}).promise;
        const pages=[];
        const stroke=(tool,width,points)=>({tool,width,color:'#000000',points});
        for(let n=1;n<=4;n++) {
          const page=await input.getPage(n), operations=[];
          for(const [i,width] of [4,8,12].entries()) {
            const y=80+i*45;
            operations.push(stroke('pen',1.2,[[40,y],[220,y]]), stroke('eraser',width,[[120,y-10],[120,y+10]]));
          }
          operations.push(stroke('pen',1.2,[[180,260]]),stroke('pen',1.2,[[110,200],[130,200]]));
          pages.push({page,operations});
        }
        const started=performance.now();
        const bytes=await generateAnswerPdf({source,pages});
        const output=await getDocument({data:bytes.slice(),worker:c.pdfWorker}).promise;
        const checks=[];
        for(let n=1;n<=4;n++) {
          const original=pages[n-1].page, p=await output.getPage(n), v=p.getViewport({scale:3});
          const canvas=document.createElement('canvas');canvas.width=v.width;canvas.height=v.height;
          const ctx=canvas.getContext('2d');await p.render({canvasContext:ctx,viewport:v}).promise;
          const pixel=(x,y)=>{const [a,b]=v.convertToViewportPoint(x,y);return Array.from(ctx.getImageData(Math.round(a),Math.round(b),1,1).data).slice(0,3);};
          const erasers=[4,8,12].map((w,i)=>({gap:pixel(120,80+i*45),edge:pixel(120+w/2+1,80+i*45),inside:pixel(120+w/2-1,80+i*45)}));
          checks.push({rotation:p.rotate,view:p.view,originalView:original.view,
            text:(await p.getTextContent()).items.map(i=>i.str).join(''),
            dot:pixel(180,260),rewritten:pixel(120,200),erasers});
          if(n===1) window.phaseCVisual=canvas.toDataURL('image/png');
          canvas.width=canvas.height=0;
        }
        const loaded=await PDFDocument.load(bytes);
        let signedRejected=false,largeRejected=false;
        const signed=await PDFDocument.load(source);
        const {PDFName}=await import('pdf-lib');signed.context.register(signed.context.obj({Type:'Sig',ByteRange:[0,1,2,3]}));
        try {await generateAnswerPdf({source:await signed.save(),pages});}catch{signedRejected=true;}
        const tooLarge=[...pages];tooLarge[0]={...pages[0],page:{view:[0,0,10000,10000],getViewport:()=>({width:40000,height:40000})}};
        try {await generateAnswerPdf({source,pages:tooLarge});}catch{largeRejected=true;}
        done({checks,bytes:bytes.length,milliseconds:performance.now()-started,signedRejected,largeRejected,
          embeddedImages:loaded.getPages().map(p=>p.node.Resources().lookup(PDFName.of('XObject')).keys().length)});

      })().catch(e=>done({error:String(e),stack:e.stack}));
    JS
    expect(result["error"]).to be_nil, result.inspect
    expect(result["signedRejected"]).to be(true)
    expect(result["largeRejected"]).to be(true)
    expect(result["embeddedImages"]).to eq([ 1, 1, 1, 1 ])
    expect(result.fetch("checks").map { |item| item["rotation"] }).to eq([ 0, 90, 180, 270 ])
    result.fetch("checks").each do |item|
      expect(item["view"]).to eq(item["originalView"])
      expect(item["text"]).to include("x^2 + 1/2 = 0.5")
      expect(item["dot"].max).to be < 80
      expect(item["rewritten"].max).to be < 80
      item["erasers"].each do |eraser|
        expect(eraser["gap"]).to eq([ 255, 0, 0 ])
        expect(eraser["inside"]).to eq([ 255, 0, 0 ])
        expect(eraser["edge"].max).to be < 80
      end
    end
    FileUtils.mkdir_p(Rails.root.join("tmp/pdfs"))
    require "base64"
    File.binwrite(Rails.root.join("tmp/pdfs/phase-c-composite.png"), Base64.decode64(page.evaluate_script("window.phaseCVisual").split(",").last))
  end

  it "shows the submitted score with the title weight and a smaller scoped font without changing its value" do
    student = Student.find_by!(attendance_number: 1)
    submission = Submission.create!(assignment: @assignment, student: student, submitted_at: Time.current, status: :completed)
    question = @assignment.questions.create!(question_label: "1", position: 1, question_text: "1+1", correct_answer: "2", grading_rule: "一致",
      answer_generation_model: "test", answer_generation_prompt_version: "v1", answer_generated_at: Time.current)
    submission.grading_results.create!(question: question, ai_judgment: :correct,
      student_answer: "2", ai_model_name: "test", prompt_version: "v1", graded_at: Time.current)
    visit student_assignments_path
    expect(page).to have_css(".student-card-score", text: "5点")
    styles = page.evaluate_script(<<~JS)
      (()=>{const card=document.querySelector('.assignment-card--submitted');
        const title=getComputedStyle(card.querySelector('.assignment-list-title'));
        const score=getComputedStyle(card.querySelector('.student-card-score'));
        return {title:title.fontWeight,score:score.fontWeight,size:parseFloat(score.fontSize),root:parseFloat(getComputedStyle(document.documentElement).fontSize)};})()
    JS
    expect(styles["score"]).to eq(styles["title"])
    expect(styles["size"]).to be_within(0.1).of(styles["root"] * 1.1)
    expect(styles["size"]).to be < styles["root"] * 1.4
    page.save_screenshot(Rails.root.join("tmp/pdfs/phase-c-score.png"))
  end

  it "measures one, three and ten A4 pages with mathematical ink at 240dpi using one temporary canvas at a time" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    result = using_wait_time(60) do
      page.evaluate_async_script(<<~JS)
      const done=arguments[arguments.length-1];
      (async()=>{
        const {PDFDocument}=await import('pdf-lib'), {getDocument}=await import('pdfjs');
        const {generateAnswerPdf}=await import('pdf_export');
        const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        const results=[];
        for(const count of [1,3,10]) {
          const doc=await PDFDocument.create();for(let n=0;n<count;n++) doc.addPage([595,842]);
          const source=await doc.save(), input=await getDocument({data:source.slice(),worker:c.pdfWorker}).promise;
          const pages=[];
          for(let n=1;n<=count;n++) {
            // Fraction bar, numerator/denominator, superscript and decimal dot.
            const lines=[[[60,700],[110,700]],[[70,710],[80,720],[90,710]],[[75,680],[90,680]],[[100,730],[105,735],[110,730]],[[115,700]]];
            pages.push({page:await input.getPage(n),operations:lines.map((points,id)=>({id,tool:'pen',width:1.2,color:'#000000',points}))});
          }
          const native=document.createElement.bind(document), canvases=[];
          document.createElement=function(tag,...args) {const node=native(tag,...args);if(tag==='canvas')canvases.push(node);return node;};
          let bytes;const started=performance.now();
          try {bytes=await generateAnswerPdf({source,pages});}finally{document.createElement=native;}
          const milliseconds=performance.now()-started;
          const reopened=await getDocument({data:bytes.slice(),worker:c.pdfWorker}).promise;
          results.push({count,outputPages:reopened.numPages,bytes:bytes.length,milliseconds,
            released:canvases.every(canvas=>canvas.width===0&&canvas.height===0),temporaryCanvases:canvases.length});
        }
        done({results});
      })().catch(error=>done({error:String(error)}));
      JS
    end
    expect(result["error"]).to be_nil, result.inspect
    result.fetch("results").each do |metric|
      expect(metric["outputPages"]).to eq(metric["count"])
      expect(metric["temporaryCanvases"]).to eq(metric["count"])
      expect(metric["released"]).to be(true)
      puts "C_A4_EXPORT_METRIC #{metric.to_json}"
    end
  end

  context "server drafts" do
    it "restores all pages, erase widths and pen/erase/pen after reload, resizing, logout and another browser session" do
      attach_preview("pdf_preview_three.pdf")
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      ink_drag(0.1, 0.25, 0.9, 0.25, 1)
      click_button "消しゴム"
      [ [ "小", 0.2 ], [ "中", 0.4 ], [ "大", 0.6 ] ].each do |label, x|
        click_button label
        ink_drag(x, 0.25, x, 0.25, 1)
      end
      click_button "ペン"
      ink_drag(0.4, 0.25, 0.4, 0.25, 1)
      ink_drag(0.8, 0.25, 0.8, 0.25, 3)
      expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存済み", wait: 10)
      draft = AnswerDraft.find_by!(assignment: @assignment)
      expect(draft.page_data.length).to eq(3)
      expect(draft.page_data.first["operations"].select { |op| op["tool"] == "eraser" }.map { |op| op["width"] }).to eq([ 4, 8, 18 ])
      page.current_window.resize_to(900, 900)
      page.refresh
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存済み")
      expect(ink_alpha(0.2, 0.25, 1)).to eq(0)
      expect(ink_alpha(0.4, 0.25, 1)).to be > 0
      expect(ink_alpha(0.6, 0.25, 1)).to eq(0)
      expect(ink_alpha(0.8, 0.25, 3)).to be > 0
      generate_preview_pdf
      page.execute_script("window.restoredPdf = window.exportBlobs[0]")
      pixels = page.evaluate_async_script(<<~JS)
        const done=arguments[arguments.length-1];
        (async()=>{
          const {getDocument}=await import('pdfjs');
          const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
          const pdf=await getDocument({data:new Uint8Array(await window.restoredPdf.arrayBuffer()),worker:c.pdfWorker}).promise;
          const results=[];
          for(const [n,x] of [[1,.2],[1,.4],[3,.8]]) {
            const p=await pdf.getPage(n),v=p.getViewport({scale:3});const canvas=document.createElement('canvas');
            canvas.width=v.width;canvas.height=v.height;const ctx=canvas.getContext('2d');
            await p.render({canvasContext:ctx,viewport:v}).promise;
            results.push(Array.from(ctx.getImageData(Math.round(v.width*x),Math.round(v.height*.25),1,1).data).slice(0,3));
            canvas.width=canvas.height=0;
          }
          done(results);
        })().catch(e=>done({error:String(e)}));
      JS
      expect(pixels.first).to eq([ 255, 255, 255 ])
      expect(pixels[1].max).to be < 20
      expect(pixels[2].max).to be < 20
      visit student_assignments_path
      click_button "ログアウト"
      expect(page).to have_field("学校コード", wait: 10)
      login_draft_student
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      expect(ink_alpha(0.4, 0.25, 1)).to be > 0
      using_session(:other_device) do
        login_draft_student
        visit student_assignment_pdf_preview_path(@assignment)
        expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
        expect(ink_alpha(0.2, 0.25, 1)).to eq(0)
        expect(ink_alpha(0.8, 0.25, 3)).to be > 0
      end
      expect(Submission.where(assignment: @assignment)).to be_empty
    end

    it "keeps edits made during a save and debounces consecutive strokes" do
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      page.execute_script(<<~JS)
        const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        const native=c.draft.request;window.draftPuts=0;
        c.draft.request=(url,options)=>{
          if(options.method==='PUT' && ++window.draftPuts===1) return new Promise(resolve=>window.releaseDraftSave=()=>resolve(native(url,options)));
          return native(url,options);
        };
      JS
      ink_drag(0.1, 0.15, 0.2, 0.15)
      ink_drag(0.3, 0.15, 0.4, 0.15)
      expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存中…", wait: 8)
      expect(page.evaluate_script("window.draftPuts")).to eq(1)
      ink_drag(0.5, 0.15, 0.6, 0.15)
      page.execute_script("window.releaseDraftSave()")
      expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存済み", wait: 12)
      expect(page.evaluate_script("window.draftPuts")).to eq(2)
      expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].length).to eq(3)
    end

    it "preserves unsaved ink after a network error and saves it on retry" do
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      page.execute_script(<<~JS)
        const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        window.draftNativeRequest=c.draft.request;c.draft.request=async()=>{throw new TypeError('offline')};
      JS
      ink_drag(0.1, 0.2, 0.6, 0.2, 1)
      expect(page).to have_text("保存できませんでした", wait: 8)
      expect(ink_alpha(0.3, 0.2)).to be > 0
      expect(AnswerDraft.where(assignment: @assignment)).to be_empty
      page.execute_script(<<~JS)
        const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        c.draft.request=window.draftNativeRequest;
      JS
      click_button "保存を再試行"
      expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存済み", wait: 10)
      page.refresh
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      expect(ink_alpha(0.3, 0.2)).to be > 0
    end

    it "stops a stale tab without overwriting the other tab or dropping local strokes" do
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      ink_drag(0.1, 0.2, 0.6, 0.2, 1)
      expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存済み", wait: 10)
      first = current_window
      second = open_new_window
      within_window(second) do
        visit student_assignment_pdf_preview_path(@assignment)
        expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
        ink_drag(0.1, 0.3, 0.6, 0.3, 1)
        expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存済み", wait: 10)
      end
      within_window(first) do
        ink_drag(0.1, 0.4, 0.6, 0.4, 1)
        expect(page).to have_text("保存を停止しました", wait: 10)
        expect(ink_alpha(0.3, 0.4)).to be > 0
        expect(page).to have_button("提出する", disabled: true)
      end
      expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].length).to eq(2)
      within_window(second) do
        page.refresh
        expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
        expect(ink_alpha(0.3, 0.3)).to be > 0
        expect(ink_alpha(0.3, 0.4)).to eq(0)
      end
    end

    it "blocks input until restoration completes and preserves the loaded operation IDs" do
      AnswerDraft.create!(student: Student.find_by!(attendance_number: 1), assignment: @assignment,
        material_fingerprint: AnswerDraftContext.fingerprint(@assignment),
        page_data: [ { page_number: 1, operations: [ { id: 7, tool: "pen", color: "#000000", width: 1.2, points: [ [ 40, 240 ] ] } ] } ])
      install_browser_script(<<~JS)
        const nativeFetch=window.fetch.bind(window);
        window.fetch=(url,options)=>String(url).includes('/answer_draft') && options.method==='GET'
          ? new Promise(resolve=>window.releaseRestore=()=>resolve(nativeFetch(url,options))) : nativeFetch(url,options);
      JS
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_text("下書きの復元中…")
      expect(page).not_to have_css('[data-pdf-preview-target="ink"]', visible: true)
      expect(page).to have_button("提出する", disabled: true)
      Timeout.timeout(10) { sleep 0.05 until page.evaluate_script("typeof window.releaseRestore === 'function'") }
      page.execute_script("window.releaseRestore()")
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      expect(ink_alpha(0.2, 0.2)).to be > 0
      ink_drag(0.3, 0.2, 0.4, 0.2, 1)
      expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存済み", wait: 10)
      expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].map { |op| op["id"] }).to eq([ 7, 8 ])
    end

    it "does not overlay an old draft onto a replacement material" do
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      ink_drag(0.1, 0.2, 0.5, 0.2, 1)
      expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存済み", wait: 10)
      original = AnswerDraft.find_by!(assignment: @assignment).attributes
      attach_preview("pdf_preview_three.pdf")
      page.refresh
      expect(page).to have_text("下書きを復元できません。ログイン状態・教材の変更を確認してください。", wait: 20)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      expect(page).to have_button("提出する", disabled: true)
      expect(ink_alpha(0.3, 0.2, 1)).to eq(0)
      ink_drag(0.1, 0.2, 0.5, 0.2, 1)
      expect(ink_alpha(0.3, 0.2, 1)).to eq(0)
      expect(AnswerDraft.find_by!(assignment: @assignment).attributes).to eq(original)
    end

    it "recovers from an initial restore failure and enables submission only after successful restoration" do
      AnswerDraft.create!(student: Student.find_by!(attendance_number: 1), assignment: @assignment,
        material_fingerprint: AnswerDraftContext.fingerprint(@assignment),
        page_data: [ { page_number: 1, operations: [ { id: 1, tool: "pen", color: "#000000", width: 1.2, points: [ [ 40, 240 ] ] } ] } ])
      install_browser_script(<<~JS)
        const originalFetch=window.fetch.bind(window);let failed=false;
        window.fetch=(url,options)=>{
          if(String(url).includes('/answer_draft') && options.method==='GET' && !failed) {
            failed=true;return Promise.resolve(new Response('{}',{status:503,headers:{'Content-Type':'application/json'}}));
          }
          return originalFetch(url,options);
        };
      JS
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_text("下書きを復元できませんでした", wait: 20)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      state = page.evaluate_script("(()=>{const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller=pdf-preview]'),'pdf-preview');return {active:c.active,blocked:c.draft.blocked,disposed:!!c.draft.disposed,ready:!!c.draft.ready};})()")
      expect(state).to eq("active" => true, "blocked" => false, "disposed" => false, "ready" => false)
      expect(page).to have_button("提出する", disabled: true)
      click_button "保存を再試行"
      expect(page).to have_css('[data-pdf-preview-target="draftStatus"].pdf-preview-status-quiet', text: "保存済み", wait: 15)
      expect(page).to have_button("提出する", disabled: false)
      expect(ink_alpha(0.2, 0.2)).to be > 0
    end

    it "allows finger scrolling of submitted quizzes while preventing new pen strokes and drafts" do
      Submission.create!(student: Student.find_by!(attendance_number: 1), assignment: @assignment, submitted_at: Time.current)
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_text("提出済みです。下書きは変更できません。", wait: 20)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      ink_drag(0.1, 0.1, 0.3, 0.1, 1)
      expect(ink_alpha(0.2, 0.1)).to eq(0)
      rect = find('[data-pdf-preview-target="ink"]').evaluate_script("this.getBoundingClientRect().toJSON()")
      x = (rect["x"] + rect["width"] * 0.8).round
      y = (rect["y"] + 180).round
      before = page.evaluate_script("scrollY")
      action = page.driver.browser.action
      action.add_pointer_input(:touch, "readonly-finger")
      action.move_to_location(x, y, device: "readonly-finger").pointer_down(:left, device: "readonly-finger")
        .move_to_location(x, y - 90, device: "readonly-finger").pointer_up(:left, device: "readonly-finger").perform
      Timeout.timeout(5) { sleep 0.05 until page.evaluate_script("scrollY") > before }
      expect(AnswerDraft.where(assignment: @assignment)).to be_empty
    end

    def login_draft_student
      visit student_login_path
      select "1年", from: "学年"
      select "1組", from: "クラス番号"
      select "1番", from: "出席番号"
      fill_in "学校コード", with: "PDFSYS"
      fill_in "パスワード", with: "password123"
      click_button "ログイン"
      expect(page).to have_current_path(student_assignments_path)
    end
  end

  it "opens from the list, saves the latest strokes and submits all pages without file selection" do
    attach_preview("pdf_preview_three.pdf")
    click_link "表示試験"
    expect(page).to have_current_path(student_assignment_pdf_preview_path(@assignment))
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(page).to have_no_css('input[type="file"]')
    expect(page.evaluate_script(<<~JS)).to be(true)
      (()=>{const c=document.querySelector('[data-pdf-preview-target="container"]');
        const b=document.querySelector('[data-pdf-preview-target="submit"]');
        return !!(c.compareDocumentPosition(b)&Node.DOCUMENT_POSITION_FOLLOWING) &&
          document.querySelectorAll('[data-pdf-preview-target="submit"]').length===1;})()
    JS
    ink_drag(0.2, 0.15, 0.2, 0.15, 1)
    click_button "消しゴム"
    click_button "大"
    ink_drag(0.2, 0.15, 0.2, 0.15, 1)
    click_button "ペン"
    ink_drag(0.4, 0.15, 0.4, 0.15, 1)
    ink_drag(0.8, 0.15, 0.8, 0.15, 3)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == AnswerReadingJob }
    record_leave_guard
    click_button "提出する"
    expect(page).to have_current_path(student_assignment_path(@assignment), wait: 30)
    expect(leave_guard_value).to eq("false")
    expect(page).to have_text("採点待ち")
    item = Submission.find_by!(assignment: @assignment)
    expect(item.answer_file).to be_attached
    expect(AnswerDraft.find_by!(assignment: @assignment).page_data.last["operations"].length).to eq(1)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.count { |job| job[:job] == AnswerReadingJob }).to eq(jobs_before + 1)
    result = page.evaluate_async_script(<<~JS)
      const done=arguments[arguments.length-1];
      (async()=>{
        const {getDocument,PDFWorker}=await import('pdfjs');
        const nativeWorker=new Worker('/vendor/pdfjs/6.4.299/pdf.worker.min.mjs',{type:'module'});
        const worker=new PDFWorker({port:nativeWorker});
        const bytes=await (await fetch(#{answer_student_assignment_path(@assignment).to_json})).arrayBuffer();
        const pdf=await getDocument({data:new Uint8Array(bytes),worker}).promise;
        const original=await getDocument({url:#{material_student_assignment_path(@assignment).to_json},worker}).promise;
        const pixels=[], texts=[];
        for(const [n,x] of [[1,.2],[1,.4],[3,.8]]) {
          const p=await pdf.getPage(n), v=p.getViewport({scale:3}), canvas=document.createElement('canvas');
          canvas.width=v.width;canvas.height=v.height;const ctx=canvas.getContext('2d');
          await p.render({canvasContext:ctx,viewport:v}).promise;
          pixels.push(Array.from(ctx.getImageData(Math.round(v.width*x),Math.round(v.height*.15),1,1).data).slice(0,3));
          canvas.width=canvas.height=0;
        }
        for(let n=1;n<=pdf.numPages;n++) {
          const p=await pdf.getPage(n), o=await original.getPage(n);
          texts.push(JSON.stringify((await p.getTextContent()).items.map(i=>i.str))===JSON.stringify((await o.getTextContent()).items.map(i=>i.str)));
        }
        done({count:pdf.numPages,pixels,texts});
      })().catch(e=>done({error:String(e)}));
    JS
    expect(result["error"]).to be_nil
    expect(result["count"]).to eq(3)
    expect(result["pixels"][0]).to eq([ 255, 255, 255 ])
    expect(result["pixels"][1].max).to be < 20
    expect(result["pixels"][2].max).to be < 20
    expect(result["texts"]).to eq([ true, true, true ])
    visit student_assignments_path
    click_link "表示試験"
    expect(page).to have_current_path(student_assignment_path(@assignment))
  end

  # Exercise the same PDF module used by formal submission, without a download UI.
  def generate_preview_pdf
    result = page.evaluate_async_script(<<~JS)
      const done=arguments[arguments.length-1];
      (async()=>{
        const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        const {snapshotPages,generateAnswerPdf}=await import('pdf_export');
        c.finishInput();
        window.exportSourceOperations=JSON.stringify(c.pageStates.map(s=>[...s.ink.pages.values()]));
        window.materialRequests=()=>performance.getEntriesByType('resource').filter(r=>new URL(r.name).pathname===new URL(c.urlValue,location.href).pathname).length;
        window.sourceRequestCount=window.materialRequests();
        const started=performance.now();
        const source=await c.pdf.getData();
        const bytes=await generateAnswerPdf({source,pages:snapshotPages(c.pageStates)});
        window.exportGenerationMs=performance.now()-started;
        window.exportBlobs=[new Blob([bytes],{type:'application/pdf'})];
        done({ok:true});
      })().catch(e=>done({error:String(e)}));
    JS
    expect(result).to eq("ok" => true)
  end

  def attach_preview(filename)
    @assignment.material_file.attach(io: File.open(Rails.root.join("spec/fixtures/files", filename)),
      filename: "preview.pdf", content_type: "application/pdf")
  end

  [
    [ 413, "request_too_large", "送信する手書きデータの容量" ],
    [ 422, "draft_points_limit", "細かな動きの記録" ],
    [ 422, "csrf_failed", "ログインの有効期限が切れました" ],
    [ 422, "unknown", "保存の要求を受け付けられませんでした" ]
  ].each do |status, reason, message|
    it "retains saved and unsaved ink without retrying a #{status} #{reason} rejection" do
      capacity = status == 413 || reason == "draft_points_limit"
      visit student_assignment_pdf_preview_path(@assignment)
      expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
      ink_drag(0.1, 0.1, 0.2, 0.1)
      expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
      saved = AnswerDraft.find_by!(assignment: @assignment).attributes
      page.execute_script(<<~JS)
        const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        editor.draft.delay=0;window.rejectedDraftPuts=0;
        const original=editor.draft.request;
        editor.draft.request=(url,options)=>{
          if(options.method==='PUT'){
            window.rejectedDraftPuts++;
            return Promise.resolve(new Response(JSON.stringify({error:#{reason.to_json},details:'private content must not be shown'}),
              {status:#{status},headers:{'Content-Type':'application/json'}}));
          }
          return original(url,options);
        };
      JS
      ink_drag(0.3, 0.1, 0.31, 0.1)
      expect(page).to have_text(message, wait: 10)
      expect(page).to have_text(reason == "csrf_failed" ? "画面を閉じず" : "再読み込み")
      expect(page).to have_no_text("private content")
      expect(ink_alpha(0.15, 0.1)).to be > 0
      expect(ink_alpha(0.305, 0.1)).to be > 0
      expect(page).to have_no_button("保存を再試行", visible: true)
      expect(page).to have_button("提出する", disabled: !capacity)
      page.evaluate_async_script(<<~JS)
        const done=arguments[arguments.length-1];
        const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        Promise.resolve().then(()=>editor.draft.retry()).then(()=>editor.draft.save()).then(()=>done(true));
      JS
      expect(page.evaluate_script("window.rejectedDraftPuts")).to eq(1)
      expect(AnswerDraft.find_by!(assignment: @assignment).attributes).to eq(saved)
      if capacity
        expect(ink_region_alpha(0.5, 0.2)).to eq(0)
        ink_drag(0.45, 0.2, 0.55, 0.2)
        expect(ink_region_alpha(0.5, 0.2)).to be > 0
        expect(page).to have_text(message)
        expect(page).to have_text("答案が失われる可能性")
        click_button "消しゴム"
        ink_drag(0.15, 0.08, 0.15, 0.12)
        expect(ink_region_alpha(0.15, 0.1)).to eq(0)
        expect(page).to have_text(message)
        expect(page.evaluate_script("window.rejectedDraftPuts")).to eq(1)
        record_leave_guard
        click_button "提出する"
        expect(page).to have_current_path(student_assignment_path(@assignment), wait: 30)
        expect(leave_guard_value).to eq("false")
        expect(submitted_pdf_pixel(0.5, 0.2).max).to be < 20
        expect(AnswerDraft.find_by!(assignment: @assignment).attributes).to eq(saved)
      else
        scroll_page(1)
        ink_drag(0.45, 0.2, 0.55, 0.2)
        expect(ink_region_alpha(0.5, 0.2)).to eq(0)
      end
    end
  end

  it "submits an unsaved answer when no draft record exists" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    page.execute_script(<<~JS)
      const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      editor.draft.delay=60_000;
    JS
    ink_drag(0.45, 0.2, 0.55, 0.2)
    expect(AnswerDraft.where(assignment: @assignment)).to be_empty
    record_leave_guard
    click_button "提出する"
    expect(page).to have_current_path(student_assignment_path(@assignment), wait: 30)
    expect(leave_guard_value).to eq("false")
    expect(submitted_pdf_pixel(0.5, 0.2).max).to be < 20
    expect(AnswerDraft.where(assignment: @assignment)).to be_empty
  end

  it "waits for an in-flight save and submits later visible ink from the same screen" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    page.execute_script(<<~JS)
      const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      editor.draft.delay=0;
      const original=editor.draft.request;
      editor.draft.request=(url,options)=>options.method==='PUT'
        ? new Promise(resolve=>window.releaseDraftSave=()=>resolve(original(url,options))) : original(url,options);
    JS
    ink_drag(0.1, 0.1, 0.2, 0.1)
    expect(page).to have_text("保存中…", wait: 10)
    ink_drag(0.45, 0.2, 0.55, 0.2)
    click_button "提出する"
    expect(page).to have_text("答案を準備しています…", wait: 10)
    page.execute_script("window.releaseDraftSave()")
    expect(page).to have_current_path(student_assignment_path(@assignment), wait: 30)
    expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].length).to eq(1)
    expect(submitted_pdf_pixel(0.5, 0.2).max).to be < 20
  end

  it "confirms its own committed PDF after the submission response is lost" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    page.execute_script(<<~JS)
      const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      editor.draft.delay=60_000;
      const original=editor.submissionState.bind(editor);
      editor.submissionState=async options=>{
        if(options?.method==='POST') {
          await original(options);
          sessionStorage.setItem('lostSubmissionPosts',String(Number(sessionStorage.getItem('lostSubmissionPosts')||0)+1));
          throw new TypeError('response lost');
        }
        return original(options);
      };
    JS
    ink_drag(0.45, 0.2, 0.55, 0.2)
    click_button "提出する"
    expect(page).to have_current_path(student_assignment_path(@assignment), wait: 30)
    expect(page.evaluate_script("sessionStorage.getItem('lostSubmissionPosts')")).to eq("1")
    expect(Submission.where(assignment: @assignment).count).to eq(1)
    expect(submitted_pdf_pixel(0.5, 0.2).max).to be < 20
  end

  def submitted_pdf_pixel(x, y)
    result = page.evaluate_async_script(<<~JS)
      const done=arguments[arguments.length-1];
      (async()=>{
        const {getDocument,PDFWorker}=await import('pdfjs');
        const nativeWorker=new Worker('/vendor/pdfjs/6.4.299/pdf.worker.min.mjs',{type:'module'});
        const worker=new PDFWorker({port:nativeWorker});
        const bytes=await (await fetch(#{answer_student_assignment_path(@assignment).to_json})).arrayBuffer();
        const pdf=await getDocument({data:new Uint8Array(bytes),worker}).promise;
        const page=await pdf.getPage(1),viewport=page.getViewport({scale:3});
        const canvas=document.createElement('canvas');canvas.width=viewport.width;canvas.height=viewport.height;
        const ctx=canvas.getContext('2d');await page.render({canvasContext:ctx,viewport}).promise;
        let pixel=[255,255,255];
        for(let dy=-6;dy<=6;dy++)for(let dx=-6;dx<=6;dx++) {
          const sample=Array.from(ctx.getImageData(Math.round(viewport.width*#{x})+dx,Math.round(viewport.height*#{y})+dy,1,1).data).slice(0,3);
          if(Math.max(...sample)<Math.max(...pixel)) pixel=sample;
        }
        canvas.width=canvas.height=0;done({pixel});
      })().catch(error=>done({error:String(error)}));
    JS
    expect(result["error"]).to be_nil
    result.fetch("pixel")
  end

  def ink_region_alpha(x, y)
    page.evaluate_script(<<~JS)
      (()=>{const c=document.querySelector('[data-pdf-preview-target="ink"]'),ctx=c.getContext('2d');
        let alpha=0;for(let dy=-6;dy<=6;dy++)for(let dx=-6;dx<=6;dx++)
          alpha=Math.max(alpha,ctx.getImageData(Math.round(c.width*#{x})+dx,Math.round(c.height*#{y})+dy,1,1).data[3]);
        return alpha;})()
    JS
  end

  it "matches cached ink to full replay through erasing, rewriting, resize and release" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    ink_drag(0.1, 0.1, 0.8, 0.1)
    click_button "消しゴム"
    click_button "大"
    ink_drag(0.4, 0.1, 0.5, 0.1)
    click_button "ペン"
    ink_drag(0.45, 0.1, 0.45, 0.1)
    comparisons = page.evaluate_async_script(<<~JS)
      const done=arguments[arguments.length-1];
      (async()=>{
        const {default:PdfInk}=await import('pdf_ink');
        const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        const ink=editor.pageStates[0].ink;
        const reference=new PdfInk(document.createElement('canvas'));
        reference.pages.set(1,structuredClone(ink.pages.get(1)));
        const compare=()=>{
          reference.setViewport(ink.viewport,1);
          reference.canvas.width=ink.canvas.width;
          reference.canvas.height=ink.canvas.height;
          reference.redraw();
          return {actual:[ink.canvas.width,ink.canvas.height],reference:[reference.canvas.width,reference.canvas.height],
            imageMatches:reference.canvas.toDataURL()===ink.canvas.toDataURL()};
        };
        const results=[compare()];
        ink.releaseCache(); ink.redraw(); results.push(compare());
        ink.setViewport(ink.viewport,1.5); results.push(compare());
        reference.canvas.width=reference.canvas.height=0;
        done(results);
      })().catch(error=>done({error:String(error)}));
    JS
    expect(comparisons.size).to eq(3)
    comparisons.each do |comparison|
      expect(comparison.fetch("reference")).to eq(comparison.fetch("actual"))
      expect(comparison.fetch("imageMatches")).to be(true)
    end
  end

  it "restores legacy width 12 and saves new width 18 without rewriting old operations" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    input_size = find('[data-pdf-preview-target="ink"]').evaluate_script("({ width: this.getBoundingClientRect().width, height: this.getBoundingClientRect().height })")
    ink_drag(0.1, 0.1, 0.9, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    draft = AnswerDraft.find_by!(assignment: @assignment)
    data = draft.page_data.deep_dup
    pen = data.first.fetch("operations").first
    # The fixture is 200 x 300 PDF units; WebDriver rounds input to whole CSS pixels.
    rounding_error = [ 200.0 / input_size.fetch("width"), 300.0 / input_size.fetch("height") ].map { |units_per_pixel| units_per_pixel * 0.5 + 1e-9 }
    expect(pen.fetch("tool")).to eq("pen")
    expect(pen.fetch("width")).to eq(1.2)
    [ pen.fetch("points").first, pen.fetch("points").last ].zip([ [ 20, 270 ], [ 180, 270 ] ]).each do |actual, intended|
      actual.zip(intended, rounding_error).each do |coordinate, expected, tolerance|
        expect(coordinate).to be_within(tolerance).of(expected)
      end
    end
    pen.fetch("points").each { |point| expect(point[1]).to be_within(rounding_error.last).of(270) }
    legacy = { "id" => 2, "tool" => "eraser", "width" => 12, "color" => "#000000", "points" => [ [ 40, 270 ] ] }
    data.first["operations"] << legacy
    draft.update!(page_data: data)
    page.refresh
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(ink_alpha(0.2, 0.1)).to eq(0)
    expect(ink_alpha(0.24, 0.1)).to be > 0
    click_button "消しゴム"
    click_button "大"
    ink_drag(0.6, 0.1, 0.6, 0.1)
    expect(ink_alpha(0.64, 0.1)).to eq(0)
    expect(ink_alpha(0.65, 0.1)).to be > 0
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    operations = draft.reload.page_data.first["operations"]
    expect(operations.first).to eq(pen)
    expect(operations[1]).to eq(legacy)
    expect(operations.last["width"]).to eq(18)
    page.refresh
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(ink_alpha(0.2, 0.1)).to eq(0)
    expect(ink_alpha(0.64, 0.1)).to eq(0)
    generate_preview_pdf
    expect(page.evaluate_async_script(<<~JS)).to eq([ [ 255, 255, 255 ], [ 255, 255, 255 ], [ 0, 0, 0 ] ])
      const done=arguments[arguments.length-1];
      (async()=>{
        const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        const {getDocument}=await import('pdfjs');
        const pdf=await getDocument({data:new Uint8Array(await window.exportBlobs[0].arrayBuffer()),worker:editor.pdfWorker}).promise;
        const page=await pdf.getPage(1), viewport=page.getViewport({scale:3});
        const canvas=document.createElement('canvas'); canvas.width=viewport.width;canvas.height=viewport.height;
        const context=canvas.getContext('2d');await page.render({canvasContext:context,viewport}).promise;
        // Sample the validated stroke's center, choosing the nearest pixel center.
        const [,lineY]=viewport.convertToViewportPoint(0,#{pen.fetch("points").first[1].to_json});
        const sampleY=Math.round(lineY-.5);
        const pixels=[.2,.64,.65].map(x=>Array.from(context.getImageData(Math.round(viewport.width*x),sampleY,1,1).data).slice(0,3));
        canvas.width=canvas.height=0; done(pixels);
      })().catch(error=>done({error:String(error)}));
    JS
  end

  it "keeps PDF coordinates after simulated viewport zoom and permits native pinch zoom" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(find('[data-pdf-preview-target="ink"]').evaluate_script("getComputedStyle(this).touchAction")).to eq("pinch-zoom")
    ink_drag(0.1, 0.1, 0.2, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    original = AnswerDraft.find_by!(assignment: @assignment).page_data
    begin
      page.driver.browser.execute_cdp("Emulation.setPageScaleFactor", pageScaleFactor: 2)
      expect(page.evaluate_script("visualViewport.scale")).to be_within(0.01).of(2)
      expect(page.evaluate_script(<<~JS)).to be(true)
        (()=>{
          const editor=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
          const ink=editor.pageStates[0].ink, rect=ink.canvas.getBoundingClientRect();
          const point=ink.point({clientX:rect.left+rect.width*.15,clientY:rect.top+rect.height*.1});
          return Math.abs(point[0]-30)<.001 && Math.abs(point[1]-270)<.001;
        })()
      JS
      expect(AnswerDraft.find_by!(assignment: @assignment).page_data).to eq(original)
    ensure
      page.driver.browser.execute_cdp("Emulation.setPageScaleFactor", pageScaleFactor: 1)
    end
    expect(ink_alpha(0.15, 0.1)).to be > 0
  end

  it "enables memory-only input diagnostics explicitly and correlates real document/controller events" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(page.evaluate_script(<<~JS)).to be(true)
      (() => {
        window.diagnosticPreview = window.Stimulus.getControllerForElementAndIdentifier(
          document.querySelector('[data-controller="pdf-preview"]'), 'pdf-preview');
        return !window.diagnosticPreview.inputDiagnostics && !window.diagnosticPreview.diagnosticTimer;
      })()
    JS
    expect(page).to have_no_css('[data-pdf-preview-target="diagnostics"]')
    page.execute_script("window.diagnosticPreview.startInputDiagnostics()")
    page.execute_script("window.scrollTo(0, 250)")
    ink_drag(0.1, 0.1, 0.2, 0.1)
    ink_drag(0.3, 0.1, 0.4, 0.1)
    rows = page.evaluate_script("window.diagnosticPreview.inputDiagnostics.snapshot().rows")
    documents = rows.select { |row| row["source"] == "document" && row["type"] == "pointerdown" }
    starts = rows.select { |row| row["reason"] == "stroke-started" }
    expect(documents.length).to eq(2)
    expect(starts.length).to eq(2)
    expect(documents.map { |row| row["eventId"] }).to eq(starts.map { |row| row["eventId"] })
    expect(starts.map { |row| row["inputActive"] }).to eq([ true, true ])
    expect(rows.count { |row| row["reason"] == "stroke-ended" }).to eq(2)
    expect(rows.map(&:keys).flatten.uniq).not_to include("clientX", "clientY", "points", "url", "draftContext")
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].length).to eq(2)
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(ink_alpha(0.35, 0.1)).to be > 0
    page.execute_script("window.diagnosticPreview.stopInputDiagnostics()")
    expect(page.evaluate_script("window.diagnosticPreview.inputDiagnostics")).to be_nil
    ink_drag(0.5, 0.1, 0.6, 0.1)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"].length).to eq(3)
  end

  it "shows opt-in pen counters outside the writing surface and resets only diagnostic data" do
    visit student_assignment_pdf_preview_path(@assignment, anchor: "pdf-input-diagnostics")
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(page).to have_css('[data-pdf-preview-target="diagnostics"]')
    expect(page.evaluate_script(<<~JS)).to be(true)
      (()=>{
        const panel=document.querySelector('[data-pdf-preview-target="diagnostics"]');
        const ink=document.querySelector('[data-pdf-preview-target="ink"]');
        return getComputedStyle(panel).position==='static' && panel.getBoundingClientRect().bottom<=ink.getBoundingClientRect().top;
      })()
    JS
    page.execute_script("window.scrollTo(0, 250)")
    bounds = find('[data-pdf-preview-target="ink"]').evaluate_script("this.getBoundingClientRect().toJSON()")
    y = (bounds["y"] + bounds["height"] * 0.1).round
    actions = page.driver.browser.action
    actions.add_pointer_input(:pen, "diagnostic-pen")
    2.times do |index|
      actions.move_to_location((bounds["x"] + bounds["width"] * (0.1 + index * 0.2)).round, y,
        device: "diagnostic-pen", duration: 0)
        .pointer_down(:left, device: "diagnostic-pen")
        .move_to_location((bounds["x"] + bounds["width"] * (0.2 + index * 0.2)).round, y,
          device: "diagnostic-pen", duration: 0)
        .pointer_up(:left, device: "diagnostic-pen")
    end
    actions.perform
    expect(page).to have_css('[data-pdf-preview-target="diagnosticSummary"]', text: "ペンdown W/D/C: 2/2/2")
    expect(page).to have_css('[data-pdf-preview-target="diagnosticSummary"]', text: "開始: 2 / イベントによる終了: 2 / 拒否: 0")
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(ink_alpha(0.35, 0.1)).to be > 0
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    draft = AnswerDraft.find_by!(assignment: @assignment)
    saved = draft.page_data.deep_dup

    page.execute_script(<<~JS)
      const preview=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
      preview.draftEditable=false;
      const ink=preview.pageStates[0].inkCanvas, rect=ink.getBoundingClientRect();
      ink.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,cancelable:true,pointerType:'pen',pointerId:99,
        button:0,buttons:1,clientX:rect.left+20,clientY:rect.top+20}));
      preview.draftEditable=true;
    JS
    expect(page).to have_css('[data-pdf-preview-target="diagnosticSummary"]', text: "ペンdown W/D/C: 3/3/3")
    expect(page).to have_css('[data-pdf-preview-target="diagnosticSummary"]', text: "draft-not-editable=1")
    before = find('[data-pdf-preview-target="ink"]').evaluate_script("this.toDataURL()")
    click_button "計測リセット"
    expect(page).to have_css('[data-pdf-preview-target="diagnosticSummary"]', text: "ペンdown W/D/C: 0/0/0")
    expect(page).to have_css('[data-pdf-preview-target="diagnosticSummary"]', text: "開始: 0 / イベントによる終了: 0 / 拒否: 0")
    expect(draft.reload.page_data).to eq(saved)
    expect(find('[data-pdf-preview-target="ink"]').evaluate_script("this.toDataURL()")).to eq(before)
    expect(page.evaluate_script("getComputedStyle(document.querySelector('[data-pdf-preview-target=ink]')).touchAction")).to eq("pinch-zoom")
    click_button "診断終了"
    expect(page).to have_no_css('[data-pdf-preview-target="diagnostics"]')
    expect(page.evaluate_script(<<~JS)).to eq([ nil, nil ])
      (()=>{const c=window.Stimulus.getControllerForElementAndIdentifier(document.querySelector('[data-controller="pdf-preview"]'),'pdf-preview');
        return [c.inputDiagnostics,c.diagnosticTimer];})()
    JS
    page.refresh
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(ink_alpha(0.35, 0.1)).to be > 0
    expect(page).to have_css('[data-pdf-preview-target="diagnosticSummary"]', text: "ペンdown W/D/C: 0/0/0")
    [ 820, 620 ].each do |width|
      page.current_window.resize_to(width, 1180)
      expect(page.evaluate_script(<<~JS)).to be(true)
        (()=>{
          const panel=document.querySelector('[data-pdf-preview-target="diagnostics"]');
          const ink=document.querySelector('[data-pdf-preview-target="ink"]');
          return panel.getBoundingClientRect().bottom<=ink.getBoundingClientRect().top &&
            document.documentElement.scrollWidth===document.documentElement.clientWidth;
        })()
      JS
    end
  end

  it "starts real pen ink after two resting touch contacts and restores the saved stroke" do
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    rect = find('[data-pdf-preview-target="ink"]').evaluate_script("this.getBoundingClientRect().toJSON()")
    x = (rect["x"] + rect["width"] * 0.1).round
    y = (rect["y"] + rect["height"] * 0.1).round
    %w[resting-palm-a resting-palm-b].each_with_index do |name, index|
      touch = page.driver.browser.action
      touch.add_pointer_input(:touch, name)
      touch.move_to_location(x + 80 + index * 30, y + 40, device: name).pointer_down(:left, device: name).perform
    end
    # Chrome may cancel native touch pointers when it recognizes a pinch. The unit
    # regression separately covers retained palm contacts; here check actual pen/render/save.
    pen = page.driver.browser.action
    pen.add_pointer_input(:pen, "palm-first-pen")
    pen.move_to_location(x, y, device: "palm-first-pen").pointer_down(:left, device: "palm-first-pen")
      .move_to_location((rect["x"] + rect["width"] * 0.2).round, y, device: "palm-first-pen")
      .pointer_up(:left, device: "palm-first-pen").perform
    %w[resting-palm-a resting-palm-b].each do |name|
      touch = page.driver.browser.action
      touch.add_pointer_input(:touch, name)
      touch.pointer_up(:left, device: name).perform
    end
    expect(ink_alpha(0.15, 0.1)).to be > 0
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    expect(AnswerDraft.find_by!(assignment: @assignment).page_data.first.fetch("operations").length).to eq(1)
    page.refresh
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(ink_alpha(0.15, 0.1)).to be > 0
  ensure
    # A dedicated session keeps native multi-pointer state out of later examples.
    page.driver.quit
  end

  it "accepts a browser-generated pen pointer while finger drags scroll without adding ink" do
    page.current_window.resize_to(1280, 900)
    visit student_assignment_pdf_preview_path(@assignment)
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    bounds = page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector('[data-pdf-preview-target="ink"]').getBoundingClientRect();
        return {x:r.x, y:r.y, width:r.width, height:r.height}; })()
    JS
    y = (bounds["y"] + bounds["height"] * 0.1).round
    actions = page.driver.browser.action
    actions.add_pointer_input(:pen, "test-pen")
    actions.move_to_location((bounds["x"] + bounds["width"] * 0.1).round, y, device: "test-pen")
      .pointer_down(:left, device: "test-pen")
      .move_to_location((bounds["x"] + bounds["width"] * 0.2).round, y, device: "test-pen")
      .pointer_up(:left, device: "test-pen").perform
    expect(ink_alpha(0.15, 0.1)).to be > 0

    # Send contacts in one batch with no requested pause or move duration between strokes.
    actions = page.driver.browser.action
    actions.add_pointer_input(:pen, "test-pen")
    9.times do |index|
      y = (bounds["y"] + bounds["height"] * (0.105 + index * 0.005)).round
      actions.move_to_location((bounds["x"] + bounds["width"] * 0.1).round, y, device: "test-pen", duration: 0)
        .pointer_down(:left, device: "test-pen")
        .move_to_location((bounds["x"] + bounds["width"] * 0.2).round, y, device: "test-pen", duration: 0)
        .pointer_up(:left, device: "test-pen")
    end
    actions.perform
    10.times { |index| expect(ink_alpha(0.15, 0.1 + index * 0.005)).to be > 0 }
    expect(page.evaluate_script("window.getSelection().isCollapsed")).to be(true)
    expect(page).to have_css('[data-pdf-preview-target="draftStatus"]', text: "保存済み", wait: 10)
    operations = AnswerDraft.find_by!(assignment: @assignment).page_data.first["operations"]
    expect(operations.length).to eq(10)
    expect(operations.map { |operation| operation["points"].length }).to all(be >= 2)
    page.refresh
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    10.times { |index| expect(ink_alpha(0.15, 0.1 + index * 0.005)).to be > 0 }

    # Native actions are suppressed on PDF pages, without cancelling events on the tools.
    expect(page.evaluate_script(<<~JS)).to eq([ true, true, false, false ])
      (() => {
        const ink = document.querySelector('[data-pdf-preview-target="ink"]');
        const tool = document.querySelector('[data-pdf-preview-target="tool"]');
        return [ink, tool].flatMap(element => ['selectstart', 'contextmenu'].map(type => {
          const event = new Event(type, {bubbles:true, cancelable:true});
          element.dispatchEvent(event); return event.defaultPrevented;
        }));
      })()
    JS
    expect(page.evaluate_script(<<~JS)).to eq([ "none", "none", "none" ])
      Array.from(document.querySelectorAll('.pdf-preview-page, .pdf-preview-page canvas'))
        .map(element => getComputedStyle(element).userSelect)
    JS

    click_button "消しゴム"
    click_button "小"
    bounds = find('[data-pdf-preview-target="ink"]').evaluate_script("this.getBoundingClientRect().toJSON()")
    y = (bounds["y"] + bounds["height"] * 0.1).round
    actions = page.driver.browser.action
    actions.add_pointer_input(:pen, "test-pen")
    actions.move_to_location((bounds["x"] + bounds["width"] * 0.15).round, y, device: "test-pen")
      .pointer_down(:left, device: "test-pen").pointer_up(:left, device: "test-pen").perform
    expect(ink_alpha(0.15, 0.1)).to eq(0)

    before = find('[data-pdf-preview-target="ink"]').evaluate_script("this.toDataURL()")
    actions = page.driver.browser.action
    actions.add_pointer_input(:touch, "test-finger")
    x = (bounds["x"] + bounds["width"] * 0.8).round
    actions.move_to_location(x, y + 100, device: "test-finger")
      .pointer_down(:left, device: "test-finger")
      .move_to_location(x, y, device: "test-finger")
      .pointer_up(:left, device: "test-finger").perform
    Timeout.timeout(5) { sleep 0.05 until page.evaluate_script("window.scrollY") > 0 }
    expect(find('[data-pdf-preview-target="ink"]').evaluate_script("this.toDataURL()")).to eq(before)
  end

  it "scopes the stylus touch guard to connected ink canvases through reconnects" do
    click_link "表示試験"
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    page.execute_script(<<~JS)
      window.touchGuardCanvas = document.querySelector('[data-pdf-preview-target="ink"]');
      window.sendGuardTouch = (target, type, changed, active) => {
        const event = new Event(type, {bubbles:true, cancelable:true});
        Object.defineProperties(event, {
          changedTouches:{value:changed.map(touchType => ({touchType}))},
          touches:{value:active.map(touchType => ({touchType}))}
        });
        let calls=0;
        const prevent=event.preventDefault.bind(event);
        event.preventDefault=()=>{calls++; prevent()};
        target.dispatchEvent(event);
        return [event.defaultPrevented,calls];
      };
    JS
    expect(page.evaluate_script(<<~JS)).to eq([ [ true, 1 ], [ true, 1 ], [ false, 0 ], [ false, 0 ], [ false, 0 ], [ false, 0 ] ])
      [
        sendGuardTouch(touchGuardCanvas,'touchstart',['stylus'],['stylus']),
        sendGuardTouch(touchGuardCanvas,'touchend',['stylus'],[]),
        sendGuardTouch(touchGuardCanvas,'touchstart',['direct'],['direct']),
        sendGuardTouch(touchGuardCanvas,'touchstart',[undefined],[undefined]),
        sendGuardTouch(touchGuardCanvas,'touchstart',['direct'],['direct','direct']),
        sendGuardTouch(touchGuardCanvas,'touchend',['stylus'],['direct'])
      ]
    JS
    expect(page.evaluate_script("getComputedStyle(touchGuardCanvas).touchAction")).to eq("pinch-zoom")

    # Target removal must detach its listeners even while the controller remains connected.
    page.execute_script("touchGuardCanvas.remove()")
    expect(page).to have_no_css('[data-pdf-preview-target="ink"]')
    expect(page.evaluate_script("sendGuardTouch(touchGuardCanvas,'touchstart',['stylus'],['stylus'])")).to eq([ false, 0 ])
    page.execute_script("document.querySelector('.pdf-preview-page').append(touchGuardCanvas)")
    expect(page).to have_css('[data-pdf-preview-target="ink"]')
    expect(page.evaluate_script("sendGuardTouch(touchGuardCanvas,'touchstart',['stylus'],['stylus'])")).to eq([ true, 1 ])

    page.execute_script(<<~JS)
      window.touchGuardRoot=document.querySelector('[data-controller="pdf-preview"]');
      touchGuardRoot.removeAttribute('data-controller');
    JS
    expect(page.evaluate_script("sendGuardTouch(touchGuardCanvas,'touchend',['stylus'],[])")).to eq([ false, 0 ])
    page.execute_script("touchGuardRoot.setAttribute('data-controller','pdf-preview')")
    expect(page).to have_css('[data-pdf-preview-target="ink"]', wait: 30) { |canvas|
      canvas.evaluate_script("this !== window.touchGuardCanvas && this.width > 0")
    }
    expect(page).to have_css('.pdf-preview-pages[aria-busy="false"]', wait: 30)
    expect(page.evaluate_script(<<~JS)).to eq([ [ false, 0 ], [ true, 1 ] ])
      [sendGuardTouch(touchGuardCanvas,'touchstart',['stylus'],['stylus']),
       sendGuardTouch(document.querySelector('[data-pdf-preview-target="ink"]'),'touchstart',['stylus'],['stylus'])]
    JS
  end

  def install_browser_script(source)
    result = page.driver.browser.execute_cdp("Page.addScriptToEvaluateOnNewDocument", source: source)
    (@browser_script_ids ||= []) << result.fetch("identifier")
  end

  def record_leave_guard
    page.execute_script(<<~JS)
      sessionStorage.removeItem('issue58LeavePrevented');
      window.addEventListener('beforeunload', event => {
        sessionStorage.setItem('issue58LeavePrevented', String(event.defaultPrevented));
      }, { once: true });
    JS
  end

  def leave_guard_value
    page.evaluate_script("sessionStorage.getItem('issue58LeavePrevented')")
  end

  def assert_canvas
    result = page.evaluate_script(<<~JS)
      (() => {
        const c = document.querySelector('canvas');
        const rect = c.getBoundingClientRect();
        const pixel = c.getContext('2d').getImageData(Math.floor(c.width / 2), Math.floor(c.height / 2), 1, 1).data;
        return { ratio: rect.width / rect.height, fits: Math.abs(rect.width - c.parentElement.clientWidth) < 1,
          black: pixel[0] < 10 && pixel[1] < 10 && pixel[2] < 10 && pixel[3] === 255 };
      })()
    JS
    expect(result["ratio"]).to be_within(0.01).of(2.0 / 3)
    expect(result["fits"]).to be(true)
    expect(result["black"]).to be(true)
  end
end
