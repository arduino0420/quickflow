require "rails_helper"
require_relative "../support/demo_seed_fixture"
require "tmpdir"
require "open3"

RSpec.describe "Read-only fictional guests", type: :request do
  include DemoSeedFixture
  include ActiveSupport::Testing::TimeHelpers
  around do |example|
    old = ENV["QUICKFLOW_GUEST_LOGIN"]
    ENV["QUICKFLOW_GUEST_LOGIN"] = "true"
    Rails.application.reload_routes!
    Dir.mktmpdir("guest-spec-", Rails.root.join("tmp")) do |directory|
      @root = Pathname.new(directory)
      @root.join(".demo-isolation").write("a" * 32)
      example.run
    end
  ensure
    ENV["QUICKFLOW_GUEST_LOGIN"] = old
    Rails.application.reload_routes!
  end

  before do
    allow_any_instance_of(Demo::Seed).to receive(:guard!) { |seed| seed.instance_variable_set(:@root, @root) }
    allow(ActiveStorage::Blob.services).to receive(:fetch).with("demo_seed")
      .and_return(ActiveStorage::Service::DiskService.new(root: @root.to_s, name: "demo_seed"))
    @normal_password = SecureRandom.hex(24)
    allow(SecureRandom).to receive(:hex).and_call_original
    allow(SecureRandom).to receive(:hex).with(24).and_return(@normal_password)
    prepare_demo_seed_fixture
    allow(AiClient).to receive(:build).and_call_original
    allow(ActiveJob::Base).to receive(:perform_later).and_raise("No jobs")
  end

  def start(role)
    post "/guest/#{role}"
    expect(response).to have_http_status(:see_other)
  end

  def snapshot
    Demo::Seed::TABLE_MODELS.excluding(AuthenticationAttemptBucket).to_h do |model|
      [ model.table_name, model.order(model.primary_key).map(&:attributes) ]
    end
  end

  it "serves all three roles with explicit fictional labels and existing credential proofs" do
    original = snapshot
    { "admin" => "/admin", "teacher" => "/assignments", "student" => "/student/assignments" }.each do |role, path|
      start(role)
      get path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("架空データの閲覧専用ゲスト", "実際のAI実行結果ではありません")
      expect(response.body).not_to include("小テスト配信", "教師を新規登録", "生徒を新規登録")
    end
    expect(snapshot).to eq(original)
    expect(QuestionGenerationRequest.count).to eq(0)
    expect(Assignment.where.not(current_question_generation_request_id: nil)).not_to exist
    expect(AiClient).not_to have_received(:build)
    expect(ActiveJob::Base).not_to have_received(:perform_later)
  end

  it "returns every signed-in guest wordmark to role selection and exposes the existing teacher Excel export" do
    original = snapshot
    { "admin" => "/admin", "teacher" => "/assignments", "student" => "/student/assignments" }.each do |role, path|
      start(role)
      get path
      document = Nokogiri::HTML(response.body)
      expect(document.at_css("header a.app-brand")["href"]).to eq(root_path)
      get root_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("ゲストの役割を選択")
    end
    start("teacher")
    assignment = Assignment.joins(:teacher).find_by!(teachers: { user_id: "demo-teacher-1" })
    get assignment_path(assignment)
    document = Nokogiri::HTML(response.body)
    export = document.at_css("a.button-excel-export")
    expect(export.text).to eq("Excel出力")
    deletion = document.at_css("button[aria-describedby='guest-delete-unavailable']")
    expect(deletion.text).to eq("この小テストを削除する")
    expect(deletion.key?("disabled")).to be(true)
    expect(deletion.ancestors("form")).to be_empty
    expect(document.at_css("#guest-delete-unavailable").text).to eq("閲覧専用のため削除できません。")
    get export["href"]
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    expect(response.body.b).to start_with("PK".b)
    expect(snapshot).to eq(original)
    expect(AiClient).not_to have_received(:build)
  end

  it "links the isolated landing wordmark to only the fixed normal selection origin" do
    allow(Demo::Profile).to receive(:identity?).and_return(true)
    allow(Demo::Guest).to receive(:verify_target!) { Demo::Seed.new.verify_guest! }
    get root_path, params: { return_to: "https://untrusted.example/" }
    document = Nokogiri::HTML(response.body)
    expect(document.at_css("h1 a")["href"]).to eq("https://13-231-93-159.sslip.io/")
    expect(document.css(".home-guest-options button").map(&:text)).to eq(%w[管理者ゲストで閲覧 教師ゲストで閲覧 生徒ゲストで閲覧])
    expect(document.css(".home-description, .home-bubble")).to be_empty
    expect(document.text).not_to include("閲覧専用", "通常アカウントではログインできません", "変更・提出・実AI採点はできません")
    expect(document.text).not_to include("架空データを閲覧する")
  end

  it "keeps school and ownership boundaries on detail and authenticated PDF routes" do
    own = Assignment.joins(:teacher).find_by!(teachers: { user_id: "demo-teacher-1" })
    other = Assignment.where.not(id: own.id).first
    start("student")
    get "/student/assignments/#{own.id}"
    expect(response).to have_http_status(:ok)
    get "/student/assignments/#{own.id}/answer"
    expect(response.media_type).to eq("application/pdf")
    get "/student/assignments/#{other.id}/material"
    expect(response).to have_http_status(:not_found)
    get "/student/assignments/#{other.id}/answer"
    expect(response).to have_http_status(:not_found)
    start("teacher")
    get "/assignments/#{own.id}"
    expect(response).to have_http_status(:ok)
    submission = own.submissions.first
    get "/assignments/#{own.id}/submissions/#{submission.id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include('type="submit" name="commit"')
    get "/assignments/#{other.id}"
    expect(response).to have_http_status(:not_found)
    get "/admin"
    expect(response).to have_http_status(:forbidden)
  end

  it "denies every routed business mutation and unsafe GET before controllers parse parameters" do
    original = snapshot
    %w[admin teacher student].each do |role|
      start(role)
      # Enumerate Rails' actual route set so newly added mutation routes also fail closed.
      excluded = %w[/guest/:role /login /student/login /admin/login /logout /student/logout /admin/logout]
      Rails.application.routes.routes.each do |route|
        path = route.path.spec.to_s.delete_suffix("(.:format)")
        next if excluded.include?(path) || path.start_with?("/rails/")
        verbs = route.verb.to_s.split("|").select { |value| %w[POST PUT PATCH DELETE].include?(value) }
        verbs.each do |verb|
          public_send(verb.downcase, path.gsub(/:[a-z_]+/, "1"), params: { arbitrary: "rejected" }, as: :json)
          expect(response).to have_http_status(:forbidden), "#{verb} #{path}: #{response.status}"
        end
      end
    end
    %w[/admin/students/1/confirm_destroy /admin/students/1/edit /admin/teachers/new
      /admin/students/1/password_reset/edit /assignments/new
      /student/assignments/1/pdf_preview /student/assignments/1/answer_draft
      /student/assignments/1/answer_draft/recovery].each do |path|
      get path
      expect(response).to have_http_status(:forbidden)
    end
    post "/rails/active_storage/direct_uploads"
    expect(response).to have_http_status(:not_found)
    expect(snapshot).to eq(original)
    expect(AiClient).not_to have_received(:build)
    expect(ActiveJob::Base).not_to have_received(:perform_later)
  end

  it "revokes replaced and logged-out cookies, and expires a guest after 15 minutes" do
    start("teacher")
    key = Rails.application.config.session_options.fetch(:key)
    previous = cookies[key]
    start("student")
    current = cookies[key]
    cookies[key] = previous
    get "/assignments"
    expect(response).to have_http_status(:unauthorized)
    cookies[key] = current
    delete "/student/logout"
    cookies[key] = current
    get "/student/assignments"
    expect(response).to have_http_status(:unauthorized)
    start("teacher")
    travel 16.minutes do
      get "/assignments"
      expect(response).to have_http_status(:unauthorized)
    end
  end

  { "admin" => "/admin/logout", "teacher" => "/logout", "student" => "/student/logout" }.each do |role, path|
    it "returns #{role} logout to the demo landing and revokes the previous cookie" do
      # Production identity uses the same controller logout branch; production
      # endpoint/grant/TLS verification is exercised by the real HTTP harness.
      allow(Demo::Profile).to receive(:identity?).and_return(true)
      allow(Demo::Guest).to receive(:verify_target!) { Demo::Seed.new.verify_guest! }
      start(role)
      key = Rails.application.config.session_options.fetch(:key)
      previous = cookies[key]
      delete path
      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("管理者ゲストで閲覧", "教師ゲストで閲覧", "生徒ゲストで閲覧")
      cookies[key] = previous
      get({ "admin" => "/admin", "teacher" => "/assignments", "student" => "/student/assignments" }.fetch(role))
      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "fails closed when data, password digests or PDF bytes change" do
    start("teacher")
    Assignment.first.update!(title: "changed")
    get "/assignments"
    expect(response).to have_http_status(:service_unavailable)
    post "/guest/student"
    expect(response).to have_http_status(:not_found)
  end

  it "rejects missing manifests, unknown roles and disabled settings" do
    post "/guest/owner"
    expect(response).to have_http_status(:not_found)
    @root.join(".seed-manifest.json").rename(@root.join("manifest.saved"))
    post "/guest/admin"
    expect(response).to have_http_status(:not_found)
    ENV["QUICKFLOW_GUEST_LOGIN"] = nil
    post "/guest/admin"
    expect(response).to have_http_status(:not_found)
    Rails.application.reload_routes!
    expect { Rails.application.routes.recognize_path("/guest/admin", method: :post) }
      .to raise_error(ActionController::RoutingError)
    get "/"
    expect(response.body).not_to include("ゲストで閲覧")
  end

  it "rejects changed credentials and attachment bytes without repairing either" do
    Teacher.find_by!(user_id: "demo-teacher-1").update!(password: SecureRandom.hex(24))
    post "/guest/teacher"
    expect(response).to have_http_status(:not_found)
    blob = ActiveStorage::Blob.first
    blob.service.upload(blob.key, StringIO.new("corrupt PDF"))
    post "/guest/student"
    expect(response).to have_http_status(:not_found)
    expect(blob.download).to eq("corrupt PDF")
  end

  it "has no production routes even when the local guest flag is accidentally set" do
    allow(Rails.env).to receive(:test?).and_return(false)
    Rails.application.reload_routes!
    expect(Demo::Guest.enabled?).to be(false)
    expect { Demo::Guest.verify! }.to raise_error(Demo::Guest::Unavailable)
    expect { Rails.application.routes.recognize_path("/guest/admin", method: :post) }
      .to raise_error(ActionController::RoutingError)
  end

  it "binds guest credentials, role and nonce on the server" do
    record = Demo::Guest.record("teacher")
    nonce = SecureRandom.hex(32)
    AuthenticationAttemptBucket.create!(key_digest: Demo::Guest.key(nonce), attempts: 0,
      expires_at: Time.current + Demo::Guest::TTL)
    state = { guest_role: "teacher", guest_nonce: nonce, teacher_id: record.id,
      credential_proof: CredentialSession.issue(record) }
    expect(Demo::Guest.valid?(state)).to be(true)
    expect(Demo::Guest.valid?(state.merge(credential_proof: "invalid"))).to be(false)
    expect(Demo::Guest.valid?(state.merge(admin_id: Admin.first.id))).to be(false)
    expect(Demo::Guest.valid?(state.merge(guest_nonce: SecureRandom.hex(32)))).to be(false)
    expect(Demo::Guest.valid?(state.merge(teacher_id: Teacher.where.not(id: record.id).first.id))).to be(false)
  end

  it "limits successful starts and fails closed before any real AI client construction" do
    10.times { start("teacher") }
    post "/guest/teacher"
    expect(response).to have_http_status(:too_many_requests)
    expect { AiClient.build(api_key: "unused") }.to raise_error(Demo::Guest::Unavailable)
    expect { AuthenticationAttemptCleanupJob.perform_now }.to raise_error(Demo::Guest::Unavailable)
    expect(OpenAI::Client).not_to have_received(:new)
  end

  it "returns from a normal login through guest switching to a normal writable session" do
    post "/login", params: { session: { user_id: "demo-teacher-2", password: @normal_password } }
    expect(response).to have_http_status(:see_other)
    normal_id = Teacher.find_by!(user_id: "demo-teacher-2").id
    expect(request.session[:teacher_id]).to eq(normal_id)
    start("student")
    expect(request.session[:teacher_id]).to be_nil
    expect(request.session[:guest_nonce]).to be_present
    delete "/student/logout"
    expect(request.session[:guest_nonce]).to be_nil
    post "/login", params: { session: { user_id: "demo-teacher-2", password: @normal_password } }
    expect(response).to have_http_status(:see_other)
    expect(request.session[:teacher_id]).to eq(normal_id)
    expect(request.session[:student_id]).to be_nil
    expect(request.session[:admin_id]).to be_nil
    expect(request.session[:guest_role]).to be_nil
    expect(request.session[:guest_nonce]).to be_nil
    get "/assignments/new"
    expect(response).to have_http_status(:ok)
    own = Teacher.find(normal_id).assignments.first
    patch "/assignments/#{own.id}", params: { assignment: { title: "Normal update preserved" } }
    expect(response).to have_http_status(:see_other)
    expect(own.reload.title).to eq("Normal update preserved")
  end

  %w[off target manifest].each do |mode|
    it "does not write to an unverified #{mode} target when given an old guest cookie" do
      start("teacher")
      key = Rails.application.config.session_options.fetch(:key)
      original_cookie = cookies[key]
      case mode
      when "off"
        ENV["QUICKFLOW_GUEST_LOGIN"] = nil
      when "target"
        guarded = Demo::Seed.new(env: { "QUICKFLOW_DEMO_SEED" => "true",
          "QUICKFLOW_DEMO_ISOLATION_ID" => "a" * 32,
          "QUICKFLOW_DEMO_DATABASE" => "quickflow_test", "QUICKFLOW_DEMO_PORT" => "65000" })
        allow(guarded).to receive(:guard!).and_call_original
        allow(Demo::Seed).to receive(:new).and_return(guarded)
      when "manifest"
        Assignment.first.update!(title: "Changed manifest")
      end
      writes = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
        sql = event.payload[:sql]
        writes << sql if sql.match?(/\A\s*(INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|TRUNCATE)\b/i)
      end
      [ [ :delete, "/logout" ], [ :get, "/assignments" ] ].each do |verb, path|
        cookies[key] = original_cookie
        public_send(verb, path)
        expect(response).to have_http_status(:service_unavailable)
      end
      expect(writes).to be_empty
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end
  end

  it "enables CSRF through the supported guest startup configuration" do
    %w[true false].each do |enabled|
      output, error, status = Open3.capture3({ "QUICKFLOW_GUEST_LOGIN" => enabled },
        RbConfig.ruby, Rails.root.join("bin/rails").to_s, "runner", "--skip-executor",
        'puts "CSRF_CONFIG=#{ActionController::Base.allow_forgery_protection}"')
      expect(status.success?).to be(true), error
      expect(output).to include("CSRF_CONFIG=#{enabled}")
    end
  end

  it "requires CSRF for guest start and logout" do
    old = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    post "/guest/admin"
    expect(response).to have_http_status(:unprocessable_content)
    get "/"
    token = Nokogiri::HTML(response.body).at_css('meta[name="csrf-token"]')["content"]
    post "/guest/admin", params: { authenticity_token: token }
    expect(response).to have_http_status(:see_other)
    delete "/logout"
    expect(response).to have_http_status(:unprocessable_content)
  ensure
    ActionController::Base.allow_forgery_protection = old
  end
end
