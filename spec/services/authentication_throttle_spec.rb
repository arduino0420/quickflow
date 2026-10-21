require "rails_helper"

RSpec.describe AuthenticationThrottle do
  include ActiveSupport::Testing::TimeHelpers

  let(:school) { School.create!(school_code: "THROTTLE") }
  let(:teacher) { Teacher.create!(school: school, user_id: "throttle-teacher", password: "synthetic-secret") }

  def limiter(source: "192.0.2.1", identity: teacher.user_id, record: teacher, role: :teacher, purpose: :login)
    described_class.new(role: role, identity: identity, source: source, record: record, purpose: purpose)
  end

  it "caps one source, does not extend a blocked window and restores access at expiry" do
    travel_to Time.current.change(usec: 0) do
      10.times { expect(limiter.authenticate("wrong")).to be(false) }
      expiries = AuthenticationAttemptBucket.order(:key_digest).pluck(:expires_at)
      expect { limiter.authenticate("synthetic-secret") }.to raise_error(described_class::Limited) { |e| expect(e.retry_after).to eq(600) }
      travel 2.minutes
      expect { limiter.authenticate("wrong") }.to raise_error(described_class::Limited) { |e| expect(e.retry_after).to eq(480) }
      expect(AuthenticationAttemptBucket.order(:key_digest).pluck(:expires_at)).to eq(expiries)
      travel 8.minutes
      expect(limiter.authenticate("synthetic-secret")).to be(true)
    end
  end

  it "caps an account across sources without locking another identity or role" do
    50.times { |i| expect(limiter(source: "192.0.2.#{i}").authenticate("wrong")).to be(false) }
    expect { limiter(source: "198.51.100.1").authenticate("wrong") }.to raise_error(described_class::Limited)
    expect(limiter(identity: "different", record: nil).authenticate("wrong")).to be(false)
    expect(limiter(role: :admin, record: nil).authenticate("wrong")).to be(false)
  end

  it "limits unknown identities identically and never stores identifiers or source addresses" do
    10.times { expect(limiter(identity: "unknown-sensitive", record: nil).authenticate("wrong")).to be(false) }
    expect { limiter(identity: "unknown-sensitive", record: nil).authenticate("wrong") }.to raise_error(described_class::Limited)
    stored = AuthenticationAttemptBucket.all.map(&:attributes).to_json
    expect(stored).not_to include("unknown-sensitive", "192.0.2.1", teacher.user_id, teacher.password_digest)
    expect(AuthenticationAttemptBucket.pluck(:key_digest)).to all(match(/\A[0-9a-f]{64}\z/))
  end

  it "resets a successful account and starts a new generation after a password reset" do
    9.times { limiter.authenticate("wrong") }
    expect(limiter.authenticate("synthetic-secret")).to be(true)
    expect(AuthenticationAttemptBucket.count).to eq(0)
    10.times { limiter.authenticate("wrong") }
    teacher.update!(password: "replacement-secret")
    expect(limiter.authenticate("replacement-secret")).to be(true)
  end

  it "uses both approved reauthentication limits independently of login" do
    5.times { limiter(purpose: :reauthentication).authenticate("wrong") }
    expect { limiter(purpose: :reauthentication).authenticate("wrong") }.to raise_error(described_class::Limited)
    5.times { limiter(source: "198.51.100.2", purpose: :reauthentication).authenticate("wrong") }
    expect { limiter(source: "198.51.100.3", purpose: :reauthentication).authenticate("wrong") }.to raise_error(described_class::Limited)
    expect(limiter.authenticate("synthetic-secret")).to be(true)
  end

  it "fails closed before password comparison and also on a failed success reset" do
    expect(teacher).not_to receive(:authenticate)
    allow(AuthenticationAttemptBucket).to receive(:insert_all).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect { limiter.authenticate("synthetic-secret") }.to raise_error(described_class::Unavailable)
  end

  it "does not report successful authentication if resetting counters fails" do
    allow(AuthenticationAttemptBucket).to receive(:where).and_call_original
    instance = limiter
    allow(instance).to receive(:reset!).and_raise(ActiveRecord::StatementInvalid)
    expect { instance.authenticate("synthetic-secret") }.to raise_error(described_class::Unavailable)
  end

  it "rejects malformed passwords without raising or authenticating" do
    [ nil, [], {}, "a\0b", "x" * 73 ].each { |value| expect(limiter.authenticate(value)).to be(false) }
  end

  it "keeps an unchanged legacy password usable and enforces policy only when it changes" do
    expect(limiter.authenticate("synthetic-secret")).to be(true)
    expect { teacher.update!(password: "1") }.to raise_error(ActiveRecord::RecordInvalid)
    teacher.reload
    expect(limiter.authenticate("synthetic-secret")).to be(true)

    password = "  A long passphrase with spaces 492  "
    teacher.update!(password: password)
    expect(limiter.authenticate(password)).to be(true)
  end

  it "cleans only expired authentication buckets in bounded batches" do
    limiter.authenticate("wrong")
    future = AuthenticationAttemptBucket.pluck(:key_digest)
    AuthenticationAttemptBucket.create!(key_digest: "a" * 64, attempts: 10, expires_at: 1.second.ago)
    AuthenticationAttemptCleanupJob.perform_now
    expect(AuthenticationAttemptBucket.pluck(:key_digest)).to match_array(future)
    expect(teacher.reload.authenticate("synthetic-secret")).to be_truthy
  end
end
