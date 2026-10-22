require "rails_helper"
require "tmpdir"
require "timeout"
require_relative "../../support/demo_seed_fixture"

RSpec.describe "Demo fixture preparation" do
  include DemoSeedFixture

  around do |example|
    Dir.mktmpdir("fixture-seed-", Rails.root.join("tmp")) do |directory|
      @root = Pathname.new(directory)
      @root.join(".demo-isolation").write("c" * 32)
      example.run
    end
  end

  let(:seed) { Demo::Seed.new }

  before do
    allow(seed).to receive(:guard!) { seed.instance_variable_set(:@root, @root) }
    allow(ActiveStorage::Blob.services).to receive(:fetch).with("demo_seed")
      .and_return(ActiveStorage::Service::DiskService.new(root: @root.to_s, name: "demo_seed"))
  end

  def other_connection
    config = ApplicationRecord.connection_db_config.configuration_hash
    PG.connect(host: config[:host], port: config[:port], dbname: config[:database],
      user: config[:username], password: config[:password])
  end

  it "waits for an observed maintenance lock, then seeds on the same fixture connection" do
    main_pid = ApplicationRecord.connection.select_value("SELECT pg_backend_pid()")
    original_timeout = ApplicationRecord.connection.select_value("SHOW lock_timeout")
    ready = Queue.new
    worker = Thread.new do
      other = other_connection
      other.exec("BEGIN")
      other.exec("LOCK TABLE grading_results IN SHARE UPDATE EXCLUSIVE MODE")
      ready << true
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.5
      loop do
        blocked = other.exec_params("SELECT $1::int = ANY(pg_blocking_pids($2::int))", [ other.backend_pid, main_pid ]).getvalue(0, 0)
        break if blocked == "t"
        raise "Fixture never waited on the maintenance barrier" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.005
      end
      other.exec("ROLLBACK")
      true
    rescue StandardError => error
      ready << error
      raise
    ensure
      other&.finish
    end
    signal = Timeout.timeout(5) { ready.pop }
    raise signal if signal.is_a?(Exception)
    expect(prepare_demo_seed_fixture(seed: seed).values).to all(be >= 5)
    expect(worker.value).to be(true)
    expect(ApplicationRecord.connection.select_value("SHOW lock_timeout")).to eq(original_timeout)
    expect(seed.verify_guest!).to be(true)
  ensure
    worker&.join
  end

  it "fails within its bound without seeding or leaking the local timeout" do
    other = other_connection
    other.exec("BEGIN")
    other.exec("LOCK TABLE grading_results IN SHARE UPDATE EXCLUSIVE MODE")
    original_timeout = ApplicationRecord.connection.select_value("SHOW lock_timeout")
    expect(seed).not_to receive(:call)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { prepare_demo_seed_fixture(seed: seed, lock_timeout_ms: 100) }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
    expect(ApplicationRecord.connection.select_value("SHOW lock_timeout")).to eq(original_timeout)
    expect(School.count).to eq(0)
  ensure
    other&.exec("ROLLBACK")
    other&.finish
  end

  it "keeps the direct operator seed's immediate NOWAIT rejection" do
    other = other_connection
    other.exec("BEGIN")
    other.exec("LOCK TABLE grading_results IN SHARE UPDATE EXCLUSIVE MODE")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    expect { ApplicationRecord.transaction(requires_new: true) { seed.call } }.to raise_error(ActiveRecord::LockWaitTimeout)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    expect(School.count).to eq(0)
  ensure
    other&.exec("ROLLBACK")
    other&.finish
  end

  it "refuses use outside an outer fixture transaction" do
    allow(ApplicationRecord.connection).to receive(:transaction_open?).and_return(false)
    expect(seed).not_to receive(:call)
    expect { prepare_demo_seed_fixture(seed: seed) }.to raise_error(/outer fixture transaction/)
  end
end
