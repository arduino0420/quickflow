require "rails_helper"
require "timeout"

RSpec.describe "Thirty students sharing one source address", type: :request do
  self.use_transactional_tests = false

  before do
    @school = School.create!(school_code: "SHARED#{SecureRandom.hex(6)}")
    @room = Classroom.create!(school: @school, grade: 1, class_number: 1)
    @students = 30.times.map { |i| Student.create!(classroom: @room, attendance_number: i + 1, password: "synthetic-secret") }
    @threads = []
    @keys = []
    # Load request/controller code before concurrent requests.
    get student_login_path
  end

  after do
    @threads.each { |thread| thread.join(30) }
    raise "Authentication workers still running" if @threads.any?(&:alive?)

    AuthenticationAttemptBucket.where(key_digest: @keys).delete_all
    @students.each(&:destroy!)
    @room.destroy!
    @school.destroy!
  end

  def input(actor, password)
    { student_session: { school_code: @school.school_code, grade: "1", class_number: "1",
      attendance_number: actor.attendance_number.to_s, password: password } }
  end

  def simultaneous_login(actors)
    ready = Queue.new
    release = Queue.new
    results = Queue.new
    actors.each do |actor|
      @threads << Thread.new do
        ready << true
        release.pop
        ActiveRecord::Base.connection_pool.with_connection do
          browser = ActionDispatch::Integration::Session.new(Rails.application)
          browser.post student_login_path, params: input(actor, "synthetic-secret"), headers: { "REMOTE_ADDR" => "192.0.2.30" }
          if browser.response.status == 303
            browser.get student_assignments_path, headers: { "REMOTE_ADDR" => "192.0.2.30" }
          end
          results << [ browser.response.status, browser.request.session[:student_id], actor.id ]
        end
      rescue StandardError => error
        results << error.class.name
      end
    end
    Timeout.timeout(30) do
      actors.length.times { ready.pop }
      actors.length.times { release << true }
      actors.length.times.map { results.pop }
    end
  end

  it "authenticates thirty distinct students concurrently behind the same address" do
    expect(simultaneous_login(@students)).to match_array(@students.map { |actor| [ 200, actor.id, actor.id ] })
  end

  it "keeps twenty-nine classmates usable while an attacker locks only one target" do
    target = @students.first
    instance = AuthenticationThrottle.new(role: :student, identity: [ @school.school_code, "1", "1", "1" ],
      record: target, source: "192.0.2.30")
    @keys = instance.instance_variable_get(:@buckets).map(&:first)
    10.times { post student_login_path, params: input(target, "wrong"), headers: { "REMOTE_ADDR" => "192.0.2.30" } }
    post student_login_path, params: input(target, "synthetic-secret"), headers: { "REMOTE_ADDR" => "192.0.2.30" }
    expect(response.status).to eq(429)
    expect(simultaneous_login(@students.drop(1))).to match_array(@students.drop(1).map { |actor| [ 200, actor.id, actor.id ] })
  end
end
