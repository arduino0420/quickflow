require "spec_helper"
require "tmpdir"
require "fileutils"
require "open3"
require_relative "../../script/lib/javascript_dependency_audit"

RSpec.describe JavascriptDependencyAudit do
  let(:root) { File.expand_path("../..", __dir__) }

  def fixture
    Dir.mktmpdir("javascript-audit-") do |directory|
      @fixture = Pathname.new(directory)
      FileUtils.mkdir_p(@fixture.join("config"))
      FileUtils.mkdir_p(@fixture.join("app/javascript"))
      FileUtils.mkdir_p(@fixture.join("public/vendor/example/1.2.3"))
      @fixture.join("app/javascript/application.js").write("// application\n")
      @fixture.join("public/vendor/example/1.2.3/library.js").write("// library\n")
      @fixture.join("config/importmap.rb").write("pin 'application'\npin 'example', to: '/vendor/example/1.2.3/library.js'\n")
      @entries = [ { "pin" => "example", "registry" => "npm", "package" => "example-dist", "version" => "1.2.3",
        "asset" => "/vendor/example/1.2.3/library.js", "sha256" => Digest::SHA256.hexdigest("// library\n") } ]
      write_inventory
      yield JavascriptDependencyAudit.new(root: @fixture)
    end
  end

  def write_inventory
    @fixture.join("config/javascript_dependencies.json").write(JSON.generate(@entries))
  end

  it "covers the served PDF aliases and exact upstream versions, plus gem-supplied JavaScript" do
    entries = described_class.new(root: root).inventory
    npm = entries.select { |entry| entry["registry"] == "npm" }.to_h { |entry| [ entry["package"], entry["version"] ] }
    expect(npm).to eq("pdfjs-dist" => "6.4.299", "pdf-lib" => "1.17.1",
      "@hotwired/turbo" => "8.0.23", "@hotwired/stimulus" => "3.2.2")
    expect(entries.find { |entry| entry["pin"] == "pdfjs" }.fetch("package")).to eq("pdfjs-dist")
    expect(entries.find { |entry| entry["pin"] == "@hotwired/stimulus-loading" })
      .to include("registry" => "rubygems", "package" => "stimulus-rails", "version" => "1.3.4")
  end

  it "submits all four npm identities and fixed versions in one nonempty request" do
    submitted = nil
    audit = described_class.new(root: root, transport: ->(packages) {
      submitted = packages
      Struct.new(:code, :body).new("200", "{}")
    })
    result = audit.audit
    expect(submitted).to eq("pdfjs-dist" => [ "6.4.299" ], "pdf-lib" => [ "1.17.1" ],
      "@hotwired/turbo" => [ "8.0.23" ], "@hotwired/stimulus" => [ "3.2.2" ])
    expect(result[:advisories]).to eq({})
  end

  it "fails before contacting the registry when an additional dependency is not registered" do
    fixture do
      @fixture.join("config/importmap.rb").open("a") { |file| file.puts "pin 'another', to: 'https://example.invalid/another.js'" }
      transport = double("transport")
      expect(transport).not_to receive(:call)
      expect { described_class.new(root: @fixture, transport: transport).audit }
        .to raise_error(described_class::InvalidInventory, "uncovered_or_stale_pins")
    end
  end

  it "rejects an empty inventory instead of reporting a clean audit" do
    fixture do |audit|
      @entries = []; write_inventory
      expect { audit.inventory }.to raise_error(described_class::InvalidInventory, "empty_inventory")
    end
  end

  it "rejects stale entries after a pin is removed" do
    fixture do |audit|
      @fixture.join("config/importmap.rb").write("pin 'application'\n")
      expect { audit.inventory }.to raise_error(described_class::InvalidInventory, "uncovered_or_stale_pins")
    end
  end

  it "rejects duplicate identities, version ranges, changed paths and changed bytes" do
    fixture do |audit|
      original = @entries.to_json
      [ -> { @entries << @entries.first.dup }, -> { @entries.first["version"] = "^1.2.3" },
        -> { @entries.first["asset"] = "/vendor/example/9.9.9/library.js" },
        -> { @entries.first["sha256"] = "0" * 64 } ].each do |change|
        @entries = JSON.parse(original); change.call; write_inventory
        expect { audit.inventory }.to raise_error(described_class::InvalidInventory)
      end
    end
  end

  it "rejects missing assets, malformed manifests, and invalid importmaps" do
    fixture do |audit|
      @fixture.join("config/javascript_dependencies.json").write("[")
      expect { audit.inventory }.to raise_error(described_class::InvalidInventory)
      write_inventory
      @fixture.join("public/vendor/example/1.2.3/library.js").rename(@fixture.join("public/vendor/example/1.2.3/removed.js"))
      expect { audit.inventory }.to raise_error(described_class::InvalidInventory, "asset_changed_or_missing")
      @fixture.join("config/importmap.rb").write("pin (\n")
      expect { audit.inventory }.to raise_error(described_class::InvalidInventory, "invalid_importmap")
    end
  end

  it "rejects a directory outside the application source instead of silently ignoring it" do
    fixture do |audit|
      @fixture.join("config/importmap.rb").open("a") { |file| file.puts "pin_all_from 'vendor/javascript', under: 'vendor'" }
      expect { audit.inventory }.to raise_error(described_class::InvalidInventory, "unsupported_directory")
    end
  end

  it "rejects gem upgrades until their served asset inventory is reviewed" do
    entries = JSON.parse(File.read(File.join(root, "config/javascript_dependencies.json")))
    entries.first["gem_version"] = "0.0.0"
    allow(JSON).to receive(:parse).and_return(entries)
    expect { described_class.new(root: root).inventory }.to raise_error(described_class::InvalidInventory, "gem_version_changed")
  end

  it "does not accept a successful but malformed or unrelated registry response" do
    [ "null", "[]", "not json", '{"unrequested":[{"title":"issue"}]}', '{"pdf-lib":{}}', '{"pdf-lib":[{}]}' ].each do |body|
      audit = described_class.new(root: root, transport: ->(_) { Struct.new(:code, :body).new("200", body) })
      expect { audit.audit }.to raise_error(described_class::Unavailable, "invalid_response")
    end
  end

  def cli(status: "200", body: "{}", outage: false, empty_inventory: false)
    # Stub the HTTP transport in the child only. Never issue a real API request in RSpec.
    script = <<~'RUBY'
      require "net/http"
      status, body, outage, empty_inventory = ARGV[1..]
      Net::HTTP.define_singleton_method(:start) do |*args, **options, &block|
        raise IOError, "PRIVATE TRANSPORT DETAILS" if outage == "true"
        client = Object.new
        client.define_singleton_method(:post) { |*| Struct.new(:code, :body).new(status, body) }
        block.call(client)
      end
      if empty_inventory == "true"
        require "json"
        JSON.define_singleton_method(:parse) { |*args| [] }
      end
      load ARGV[0]
    RUBY
    Open3.capture3(RbConfig.ruby, "-e", script, File.join(root, "bin/audit-javascript"), status, body, outage.to_s, empty_inventory.to_s)
  end

  it "reports the inspected inventory and completed npm request with exit 0" do
    stdout, stderr, status = cli
    expect(status.exitstatus).to eq(0), stderr
    events = stdout.lines.map { |line| JSON.parse(line) }
    expect(events.first.fetch("dependencies").length).to eq(5)
    expect(events.last).to include("event" => "javascript_audit_passed", "advisories" => {})
    expect(events.last.fetch("packages").keys).to contain_exactly("@hotwired/turbo", "@hotwired/stimulus", "pdfjs-dist", "pdf-lib")
  end

  it "reports a detected advisory with exit 1, separately from an unavailable audit" do
    stdout, _, status = cli(body: '{"pdfjs-dist":[{"title":"Synthetic advisory","severity":"high"}]}')
    expect(status.exitstatus).to eq(1)
    expect(JSON.parse(stdout.lines.last).fetch("event")).to eq("javascript_vulnerabilities_found")
  end

  it "reports an HTTP failure with exit 2 and never emits a clean result" do
    stdout, stderr, status = cli(status: "503", body: "PRIVATE RESPONSE")
    expect(status.exitstatus).to eq(2)
    expect(JSON.parse(stderr)).to include("event" => "javascript_audit_unavailable", "reason" => "http_status_503")
    expect(stdout).not_to include("javascript_audit_passed", "PRIVATE")
  end

  it "reports invalid JSON as unavailable with exit 2" do
    stdout, stderr, status = cli(body: "not JSON")
    expect(status.exitstatus).to eq(2)
    expect(JSON.parse(stderr).fetch("reason")).to eq("invalid_response")
    expect(stdout).not_to include("javascript_audit_passed")
  end

  it "reports transport failure with exit 2 without disclosing exception details" do
    stdout, stderr, status = cli(outage: true)
    expect(status.exitstatus).to eq(2)
    expect(JSON.parse(stderr)).to include("event" => "javascript_audit_unavailable", "reason" => "transport_IOError")
    expect(stdout + stderr).not_to include("PRIVATE", "javascript_audit_passed")
  end

  it "reports an empty target as invalid with exit 2 and makes no HTTP request" do
    stdout, stderr, status = cli(empty_inventory: true, outage: true)
    expect(status.exitstatus).to eq(2)
    expect(JSON.parse(stderr)).to include("event" => "javascript_inventory_invalid", "reason" => "empty_inventory")
    expect(stdout).to be_empty
  end
end
