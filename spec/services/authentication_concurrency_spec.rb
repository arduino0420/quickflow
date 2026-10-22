require "rails_helper"
require "open3"
require "timeout"

RSpec.describe "Persistent concurrent authentication limits" do
  self.use_transactional_tests = false

  before do
    @identity = "process-#{SecureRandom.hex(12)}"
    @keys = []
    @workers = []
  end

  after do
    @workers.each do |pid|
      begin
        Timeout.timeout(10) { Process.wait(pid) }
      rescue Errno::ECHILD
        # Already collected.
      rescue Timeout::Error
        Process.kill("TERM", pid)
        Process.wait(pid)
        raise "Authentication worker timed out"
      end
    end
    AuthenticationAttemptBucket.where(key_digest: @keys.uniq).delete_all
  end

  def limiter(source = "192.0.2.80")
    instance = AuthenticationThrottle.new(role: :teacher, identity: @identity, source: source, record: nil)
    @keys.concat(instance.instance_variable_get(:@buckets).map(&:first))
    instance
  end

  def compete(per_process:, distinct_sources:)
    instances = 12.times.map { |i| limiter(distinct_sources ? "192.0.2.#{i}" : "192.0.2.80") }
    ActiveRecord::Base.connection_handler.clear_all_connections!
    start_read, start_write = IO.pipe
    readers = instances.map do |instance|
      read, write = IO.pipe
      pid = fork do
        read.close
        start_write.close
        start_read.read(1)
        accepted = limited = 0
        begin
          per_process.times do
            begin
              instance.authenticate("wrong")
              accepted += 1
            rescue AuthenticationThrottle::Limited
              limited += 1
            end
          end
          write.write(JSON.generate(accepted: accepted, limited: limited))
          write.close
          exit! 0
        rescue StandardError => error
          write.write(JSON.generate(error: error.class.name))
          write.close
          exit! 1
        end
      end
      @workers << pid
      write.close
      read
    end
    start_read.close
    start_write.write("x" * instances.length)
    start_write.close
    Timeout.timeout(30) { readers.map { |read| JSON.parse(read.read).tap { read.close } } }
  end

  it "admits at most ten simultaneous comparisons across twelve processes on one source" do
    results = compete(per_process: 1, distinct_sources: false)
    expect(results.flat_map(&:keys)).not_to include("error")
    expect(results.sum { |r| r.fetch("accepted") }).to eq(10)
    expect(results.sum { |r| r.fetch("limited") }).to eq(2)
  end

  it "admits at most fifty comparisons across processes and rotating sources" do
    results = compete(per_process: 5, distinct_sources: true)
    expect(results.flat_map(&:keys)).not_to include("error")
    expect(results.sum { |r| r.fetch("accepted") }).to eq(50)
    expect(results.sum { |r| r.fetch("limited") }).to eq(10)
  end

  it "retains limits and fixed expiries after the application exits and boots again" do
    limiter
    env = { "RAILS_ENV" => "test", "DATABASE_URL" => ENV.fetch("DATABASE_URL") }
    setup = <<~RUBY
      10.times do
        AuthenticationThrottle.new(role: :teacher, identity: ARGV[0], source: "192.0.2.80", record: nil).authenticate("wrong")
      end
      puts "reserved"
    RUBY
    output, error, status = Open3.capture3(env, RbConfig.ruby, "-r", Rails.root.join("config/environment").to_s, "-e", setup, @identity)
    expect(status.success?).to be(true), error
    expect(output).to include("reserved")
    before = AuthenticationAttemptBucket.where(key_digest: @keys).order(:key_digest).pluck(:expires_at)
    check = <<~'RUBY'
      begin
        AuthenticationThrottle.new(role: :teacher, identity: ARGV[0], source: "192.0.2.80", record: nil).authenticate("wrong")
        abort "limit lost"
      rescue AuthenticationThrottle::Limited => e
        puts "limited:#{e.retry_after}"
      end
    RUBY
    output, error, status = Open3.capture3(env, RbConfig.ruby, "-r", Rails.root.join("config/environment").to_s, "-e", check, @identity)
    expect(status.success?).to be(true), error
    expect(output).to match(/limited:[1-9][0-9]*/)
    expect(AuthenticationAttemptBucket.where(key_digest: @keys).order(:key_digest).pluck(:expires_at)).to eq(before)
  end
end
