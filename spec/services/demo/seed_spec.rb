require "rails_helper"
require "tmpdir"

RSpec.describe Demo::Seed do
  let(:token) { "a" * 32 }
  let(:env) { { "QUICKFLOW_DEMO_SEED" => "true", "QUICKFLOW_DEMO_ISOLATION_ID" => token,
    "QUICKFLOW_DEMO_DATABASE" => "quickflow_test", "QUICKFLOW_DEMO_PORT" => "57429" } }
  let(:seed) { described_class.new(env: env) }

  around do |example|
    Dir.mktmpdir("seed-spec-", Rails.root.join("tmp")) do |directory|
      @directory = Pathname.new(directory)
      @directory.join(".demo-isolation").write("a" * 32)
      example.run
    end
  end

  before do
    allow(seed).to receive(:guard!) { seed.instance_variable_set(:@root, @directory) }
    allow(OpenAI::Client).to receive(:new).and_raise("No external API")
    allow(AiClient).to receive(:build).and_raise("No AI")
    allow(ActiveJob::Base).to receive(:perform_later).and_raise("No job")
    allow(ActiveStorage::Blob.services).to receive(:fetch).with("demo_seed")
      .and_return(ActiveStorage::Service::DiskService.new(root: @directory.to_s, name: "demo_seed"))
  end

  def rows
    described_class::TABLE_MODELS.to_h { |model| [ model.table_name, model.order(model.primary_key).map(&:attributes) ] }
  end

  it "creates valid fictional associations, PDF bytes, reading JSON and draft contexts without AI or jobs" do
    expect(seed.call.values).to all(be >= 5)
    expect(ActiveStorage::Blob.count).to eq(10)
    expect(ActiveStorage::Attachment.count).to eq(10)
    expect(Submission.all.map(&:score)).to eq([ 10 ] * 5)
    expect(AnswerDraft.all.map(&:student_id) & Submission.all.map(&:student_id)).to be_empty
    ActiveStorage::Blob.find_each do |blob|
      expect(blob.download).to include("FICTIONAL DEMO SAMPLE", "xref", "%%EOF")
      expect(blob.checksum).to eq(Digest::MD5.base64digest(blob.download))
    end
    expect(AiClient).not_to have_received(:build)
    expect(OpenAI::Client).not_to have_received(:new)
    expect(ActiveJob::Base).not_to have_received(:perform_later)
  end

  it "preserves all IDs, digests, timestamps, checksums and files on rerun" do
    seed.call
    original = rows
    manifest = @directory.join(".seed-manifest.json").read
    seed.call
    expect(rows).to eq(original)
    expect(@directory.join(".seed-manifest.json").read).to eq(manifest)
  end

  it "detects timestamp changes smaller than one second" do
    seed.call
    assignment = Assignment.first
    original = assignment.updated_at
    assignment.update_columns(updated_at: original + Rational(1, 1_000_000))
    expect { seed.call }.to raise_error(described_class::UnsafeTarget, /changed/)
    expect(assignment.reload.updated_at).not_to eq(original)
  end

  it "flushes attachment parent touches before capturing the manifest" do
    captured = nil
    allow(seed).to receive(:snapshot).and_wrap_original do |method|
      captured = rows
      method.call
    end
    seed.call
    expect(rows).to eq(captured)
    expect(seed.verify_guest!).to be(true)
  end

  it "refuses unexpected database tables before writing data" do
    connection = ApplicationRecord.connection
    allow(connection).to receive(:select_rows).and_call_original
    allow(connection).to receive(:select_rows).with(/FROM pg_namespace AS namespaces/).and_return(
      described_class::TABLE_MODELS.map { |model| [ "public", model.table_name ] } + [ [ "public", "unrecognized_records" ] ])
    expect { seed.call }.to raise_error(described_class::UnsafeTarget, /Unexpected database schemas or tables/)
    expect(School.count).to eq(0)
  end

  it "rejects hidden user schemas and preserves their existing records" do
    connection = ApplicationRecord.connection
    connection.execute("CREATE SCHEMA seed_spec_archive")
    connection.execute("CREATE TABLE seed_spec_archive.retained_records (note text NOT NULL)")
    connection.execute("INSERT INTO seed_spec_archive.retained_records VALUES ('keep existing data')")
    expect(connection.tables).not_to include("retained_records")
    expect { seed.call }.to raise_error(described_class::UnsafeTarget, /Unexpected database schemas or tables/)
    expect(connection.select_value("SELECT note FROM seed_spec_archive.retained_records")).to eq("keep existing data")
    expect(School.count).to eq(0)
  end

  it "rejects user temporary tables without confusing them with PostgreSQL catalogs" do
    connection = ApplicationRecord.connection
    connection.execute("CREATE TEMP TABLE seed_spec_temporary (note text NOT NULL)")
    connection.execute("INSERT INTO seed_spec_temporary VALUES ('keep temporary data')")
    expect { seed.call }.to raise_error(described_class::UnsafeTarget, /Unexpected database schemas or tables/)
    expect(connection.select_value("SELECT note FROM seed_spec_temporary")).to eq("keep temporary data")
  end

  it "rejects empty unexpected user schemas too" do
    ApplicationRecord.connection.execute("CREATE SCHEMA seed_spec_empty")
    expect { seed.call }.to raise_error(described_class::UnsafeTarget, /Unexpected database schemas or tables/)
    expect(School.count).to eq(0)
  end

  it "refuses preexisting non-demo data without changing it" do
    school = School.create!(school_code: "EXISTING")
    expect { seed.call }.to raise_error(described_class::UnsafeTarget, /empty dedicated database/)
    expect(School.all).to eq([ school ])
  end

  it "refuses changed demo data without repairing it" do
    seed.call
    Assignment.first.update!(title: "Changed")
    original = rows
    expect { seed.call }.to raise_error(described_class::UnsafeTarget, /changed/)
    expect(rows).to eq(original)
  end

  it "refuses unknown storage files without deleting them" do
    @directory.join("unrelated").write("keep")
    expect { seed.call }.to raise_error(described_class::UnsafeTarget, /Storage is not empty/)
    expect(@directory.join("unrelated").read).to eq("keep")
  end

  it "rolls back DB on a partial storage failure, preserves files and refuses a blind retry" do
    service = ActiveStorage::Blob.services.fetch("demo_seed")
    uploads = 0
    allow(service).to receive(:upload).and_wrap_original do |method, *args, **kwargs|
      uploads += 1
      raise IOError, "injected storage failure" if uploads == 2
      method.call(*args, **kwargs)
    end
    expect { seed.call }.to raise_error(IOError, /injected/)
    expect(described_class::TABLE_MODELS.map(&:count)).to all(eq(0))
    expect(@directory.join(".seed-manifest.json")).not_to exist
    expect(@directory.glob("**/*").select(&:file?)).not_to be_empty
    expect { seed.call }.to raise_error(described_class::UnsafeTarget, /Storage is not empty/)
  end

  it "leaves committed data intact and fails closed if manifest persistence fails" do
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with(@directory.join(".seed-manifest.json"),
      File::WRONLY | File::CREAT | File::EXCL, 0o600).and_raise(IOError, "manifest unavailable")
    expect { seed.call }.to raise_error(IOError, /manifest unavailable/)
    expect(School.count).to eq(5)
    original = rows
    expect { seed.call }.to raise_error(described_class::UnsafeTarget, /empty dedicated database/)
    expect(rows).to eq(original)
  end

  it "refuses missing or corrupted PDF bytes without purging anything" do
    seed.call
    blob = ActiveStorage::Blob.first
    blob.service.upload(blob.key, StringIO.new("corrupt"))
    expect { seed.call }.to raise_error(ActiveStorage::IntegrityError)
    expect(blob.reload.service.exist?(blob.key)).to be(true)
  end

  it "rejects concurrent runs holding the storage lock" do
    File.open(@directory.join(".seed.lock"), "w") do |lock|
      lock.flock(File::LOCK_EX)
      expect { seed.call }.to raise_error(described_class::UnsafeTarget, /already running/)
    end
    expect(School.count).to eq(0)
  end

  it "rejects concurrent database writers instead of waiting" do
    ready = Queue.new
    release = Queue.new
    config = ApplicationRecord.connection_db_config.configuration_hash
    writer = Thread.new do
      # Rails transactional fixtures share their pinned connection across threads.
      # A separate PG connection is necessary to test a real competing writer.
      other = PG.connect(host: config[:host], port: config[:port], dbname: config[:database],
        user: config[:username], password: config[:password])
      other.exec("BEGIN")
      other.exec("LOCK TABLE schools IN EXCLUSIVE MODE")
      ready << true
      release.pop
    ensure
      other&.exec("ROLLBACK")
      other&.finish
    end
    ready.pop
    expect { seed.call }.to raise_error(ActiveRecord::LockWaitTimeout)
  ensure
    release << true if release
    writer&.join
  end

  it "rejects extra files on rerun while preserving the database" do
    seed.call
    original = rows
    @directory.join("unrelated").write("keep")
    expect { seed.call }.to raise_error(described_class::UnsafeTarget, /changed/)
    expect(rows).to eq(original)
    expect(@directory.join("unrelated").read).to eq("keep")
  end

  it "does not create demo records through ordinary db/seeds.rb" do
    load Rails.root.join("db/seeds.rb")
    expect(described_class::TABLE_MODELS.map(&:count)).to all(eq(0))
  end

  context "target guard" do
    before do
      allow(seed).to receive(:guard!).and_call_original
    end

    it "is disabled by default" do
      env.delete("QUICKFLOW_DEMO_SEED")
      expect { seed.call }.to raise_error(described_class::UnsafeTarget, /disabled/)
    end

    it "rejects development and production environments" do
      allow(Rails.env).to receive(:test?).and_return(false)
      expect { seed.call }.to raise_error(described_class::UnsafeTarget, /Only test/)
    end

    it "rejects missing isolation settings" do
      env.delete("QUICKFLOW_DEMO_ISOLATION_ID")
      expect { seed.call }.to raise_error(described_class::UnsafeTarget, /Missing isolation/)
    end

    it "rejects an actual endpoint or database marker mismatch" do
      expect { seed.call }.to raise_error(described_class::UnsafeTarget, /endpoint or isolation marker/)
    end
    context "with a matching observed endpoint" do
      before do
        connection = ApplicationRecord.connection
        allow(connection).to receive(:select_one).and_call_original
        allow(connection).to receive(:select_one).with(/SELECT current_database/).and_return(
          { "database" => "quickflow_test", "host" => "127.0.0.1", "port" => "57429", "marker" => "quickflow-demo:#{token}" })
        allow(ApplicationRecord).to receive(:connection_db_config).and_return(
          double(configuration_hash: { database: "quickflow_test", host: "127.0.0.1", port: 57429 }))
        allow(Rails.root).to receive(:join).and_call_original
        allow(Rails.root).to receive(:join).with("tmp", "demo-seed-#{token}").and_return(@directory)
      end

      it "accepts matching database configuration, marker and dedicated Disk storage" do
        expect(seed.call.values).to all(be >= 5)
      end

      it "rejects configured endpoint mismatches" do
        allow(ApplicationRecord).to receive(:connection_db_config).and_return(
          double(configuration_hash: { database: "quickflow_test", host: "localhost", port: 57429 }))
        expect { seed.call }.to raise_error(described_class::UnsafeTarget, /configuration differs/)
      end

      it "rejects the default port even with an isolation marker" do
        env["QUICKFLOW_DEMO_PORT"] = "5432"
        expect { seed.call }.to raise_error(described_class::UnsafeTarget, /endpoint/)
      end

      it "rejects storage marker mismatches" do
        @directory.join(".demo-isolation").write("different")
        expect { seed.call }.to raise_error(described_class::UnsafeTarget, /Storage isolation marker/)
      end

      it "rejects a shared storage root" do
        allow(ActiveStorage::Blob.services).to receive(:fetch).with("demo_seed").and_return(
          ActiveStorage::Service::DiskService.new(root: Rails.root.join("tmp/storage").to_s))
        expect { seed.call }.to raise_error(described_class::UnsafeTarget, /Storage directory/)
      end

      it "rejects symbolic links inside storage" do
        File.symlink(@directory.join(".demo-isolation"), @directory.join("redirect"))
        expect { seed.call }.to raise_error(described_class::UnsafeTarget, /symbolic links/)
      end
    end
  end
end
