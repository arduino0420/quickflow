require "rails_helper"
require "tmpdir"

RSpec.describe "Read-only fictional guests", type: :request do
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
    Demo::Seed.new.call
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
    expect(AiClient).not_to have_received(:build)
    expect(ActiveJob::Base).not_to have_received(:perform_later)
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
        verb = route.verb.to_s.split("|").find { |value| %w[POST PUT PATCH DELETE].include?(value) }
        next unless verb
        public_send(verb.downcase, path.gsub(/:[a-z_]+/, "1"), params: { arbitrary: "rejected" }, as: :json)
        expect(response).to have_http_status(:forbidden), "#{verb} #{path}: #{response.status}"
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
