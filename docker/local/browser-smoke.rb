# Host-Mac browser smoke; no Rails boot or DB connections. Run with native Ruby.
# Uses only a brand-new Chrome profile. Never disables the browser sandbox.
require "json"
require "securerandom"
require "pathname"
require "fileutils"
require "open3"
require "uri"
require "openssl"
require "socket"
require "base64"
require "timeout"
require "time"
require_relative "certificate-proof"
gem "selenium-webdriver", "4.52.0"
require "selenium-webdriver"
require "zip"
require "rexml/document"
MODE = ARGV.fetch(0, "dev")
raise "Mode must be dev or check" unless %w[dev check].include?(MODE)
BASE = MODE == "dev" ? "http://localhost:18080" : "https://localhost:18444"
ROOT = Pathname.new(__dir__).join("../..").expand_path
fixture_path = ROOT.join(".local/#{MODE}/http-fixture.private.json")
identity = JSON.parse(fixture_path.read)
raise "Not a synthetic fixture for this mode" unless identity["mode"] == MODE && identity["run"].start_with?("HTTPLOCAL")
# SPKI is a public-key pin, not a leaf pin. First verify the exact current leaf,
# and never use accept_insecure_certs or a broad ignore-certificate-errors flag.
spki_pin = nil
if MODE == "check"
  raise "Certificate-specific opt-in required" unless ENV["QF_LOCAL_PINNED_CERT_OPT_IN"] == "1"
  proof = JSON.parse(ROOT.join(".local/check/browser-certificate-proof.json").read)
  raise "Wrong certificate proof" unless proof["base_url"] == BASE && proof["project"] == "qfl-check-#{OpenSSL::Digest::SHA256.hexdigest(ROOT.to_s)[0, 10]}" &&
    proof["container_id"].to_s.match?(/\A[0-9a-f]{64}\z/) && proof["der_sha256"].to_s.match?(/\A[0-9a-f]{64}\z/) &&
    proof["san_dns"] == [ "localhost" ] && proof["spki_sha256_base64"].to_s.match?(/\A[A-Za-z0-9+\/]{43}=\z/)
  generated_at = Time.iso8601(proof.fetch("generated_at"))
  raise "Certificate proof expired or from future" unless (0..600).cover?(Time.now - generated_at)
  docker, caddy = LocalCertificateProof.current_caddy
  raise "Caddy changed since certificate proof" unless caddy["Id"] == proof["container_id"] && caddy["Image"] == proof["image_id"]
  raise "Explicit SPKI does not match proof" unless ENV["QF_LOCAL_CERT_SPKI"] == proof["spki_sha256_base64"]
  cert = LocalCertificateProof.verified_live_certificate(docker, caddy)
  actual_der = OpenSSL::Digest::SHA256.hexdigest(cert.to_der)
  actual_spki = Base64.strict_encode64(OpenSSL::Digest::SHA256.digest(cert.public_key.public_to_der))
  sans = cert.extensions.select { |ext| ext.oid == "subjectAltName" }.flat_map { |ext| ext.value.split(/,\s*/) }
  raise "Leaf certificate mismatch" unless actual_der == proof["der_sha256"]
  raise "Public-key mismatch" unless actual_spki == proof["spki_sha256_base64"]
  raise "Wrong SAN" unless sans == [ "DNS:localhost" ]
  raise "Certificate is not currently valid" unless cert.not_before <= Time.now && Time.now < cert.not_after
  spki_pin = actual_spki
end
run_root = ROOT.join(".local/#{MODE}/browser-#{SecureRandom.hex(6)}")
FileUtils.mkdir_p(run_root, mode: 0700)
profile = run_root.join("profile")
downloads = run_root.join("downloads")
FileUtils.mkdir_p(downloads, mode: 0700)
chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
version, status = Open3.capture2("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleShortVersionString", "/Applications/Google Chrome.app/Contents/Info.plist")
raise "Chrome version unavailable" unless status.success?
major = version.strip.split(".").first
driver_path = Dir.glob(File.join(Dir.home, ".cache/selenium/chromedriver/mac-x64", "#{major}.*", "chromedriver")).max_by { |path| Gem::Version.new(File.basename(File.dirname(path))) }
raise "No cached matching ChromeDriver; do not silently download" unless driver_path

module BrowserProof
  def self.check(name, ok)
    raise "Check failed: #{name}" unless ok
    puts JSON.generate(check: name, passed: true); STDOUT.flush
  end
  def self.local_uri(value)
    uri = URI(value)
    base = URI(BASE)
    raise "Navigation outside fixed local origin refused" unless uri.scheme == base.scheme && uri.host == base.host && uri.port == base.port && uri.userinfo.nil?
    uri
  end
  def self.pdf
    stream = "BT /F1 18 Tf 40 700 Td (SYNTHETIC BROWSER TEST: 1+1=2) Tj ET\n"
    objects = [ "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>", "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>", "<< /Length #{stream.bytesize} >>\nstream\n#{stream}endstream", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>" ]
    out = +"%PDF-1.4\n"
    offsets=objects.each_with_index.map { |o, i| pos=out.bytesize; out << "#{i+1} 0 obj\n#{o}\nendobj\n"; pos }
    xref=out.bytesize; out << "xref\n0 6\n0000000000 65535 f \n"
    offsets.each { |n| out << format("%010d 00000 n \n", n) }
    out << "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n#{xref}\n%%EOF\n"
  end
end
options = Selenium::WebDriver::Chrome::Options.new
options.binary = chrome
options.accept_insecure_certs = false
options.add_argument("--ignore-certificate-errors-spki-list=#{spki_pin}") if spki_pin
[ "--headless=new", "--window-size=1280,1000", "--user-data-dir=#{profile}", "--no-first-run", "--disable-background-networking" ].each { |arg| options.add_argument(arg) }
options.add_preference(:download, default_directory: downloads.to_s, prompt_for_download: false)
options.add_preference(:credentials_enable_service, false)
options.add_preference(:profile, password_manager_enabled: false)
driver = nil
stage = "browser_start"
begin
  driver = Selenium::WebDriver.for(:chrome, options: options, service: Selenium::WebDriver::Service.chrome(path: driver_path))
  wait = Selenium::WebDriver::Wait.new(timeout: 120, interval: 0.2)
  element = ->(css) { wait.until { BrowserProof.local_uri(driver.current_url); driver.find_elements(css: css).find(&:displayed?) } }
  button = lambda do |text|
    BrowserProof.local_uri(driver.current_url)
    target = wait.until { driver.find_elements(xpath: "//button[normalize-space(.)='#{text}'] | //input[@type='submit' and @value='#{text}']").find { |e| e.displayed? && e.enabled? } }
    form = target.find_elements(xpath: "ancestor::form[1]").first
    BrowserProof.local_uri(form.attribute("action")) if form
    target.click
  end
  teacher_login = lambda do
    driver.navigate.to(BASE + "/login")
    element.call("#session_user_id").send_keys(identity.fetch("teacher_user"))
    element.call("#session_password").send_keys(identity.fetch("password"))
    button.call("ログイン")
    wait.until { BrowserProof.local_uri(driver.current_url).path == "/assignments" }
  end
  stage = "teacher_login"
  teacher_login.call
  BrowserProof.check(stage, true)
  stage = "pdf_distribution"
  driver.navigate.to(BASE + "/assignments/new")
  title = "Browser synthetic #{SecureRandom.hex(7)}"
  element.call("#assignment_title").send_keys(title)
  points=element.call("#assignment_point_per_question"); points.clear; points.send_keys("5")
  pdf_path = run_root.join("synthetic.pdf"); File.binwrite(pdf_path, BrowserProof.pdf)
  driver.find_element(css: "#assignment_material_file").send_keys(pdf_path.to_s)
  element.call("#classroom_#{identity.fetch('classroom_id')}").click
  button.call("配信")
  assignment_link = wait.until { driver.find_elements(css: ".assignment-card-link").find { |e| e.text.include?(title) } }
  assignment_path = BrowserProof.local_uri(assignment_link.attribute("href")).path
  aid=assignment_path.split("/").last
  BrowserProof.check(stage, true)
  driver.manage.delete_all_cookies
  stage = "student_login"
  driver.navigate.to(BASE + "/student/login")
  element.call("#student_session_school_code").send_keys(identity.fetch("school_code"))
  %w[grade class_number attendance_number].each { |field| Selenium::WebDriver::Support::Select.new(element.call("#student_session_#{field}")).select_by(:value, "1") }
  element.call("#student_session_password").send_keys(identity.fetch("password")); button.call("ログイン")
  wait.until { BrowserProof.local_uri(driver.current_url).path == "/student/assignments" }
  BrowserProof.check(stage, true)
  preview_path="/student/assignments/#{aid}/pdf_preview"
  stage = "pdfjs_render"
  driver.navigate.to(BASE+preview_path)
  element.call('.pdf-preview-pages[aria-busy="false"]')
  BrowserProof.check(stage, driver.find_elements(css: '[data-pdf-preview-target="canvas"]').any?)
  stage = "actual_pointer_handwriting"
  button.call("ペン")
  canvas=element.call('[data-pdf-preview-target="ink"]')
  driver.execute_script("arguments[0].scrollIntoView({block:'center'})", canvas)
  rect=driver.execute_script("const r=arguments[0].getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}", canvas)
  viewport = driver.execute_script("return {width:innerWidth,height:innerHeight}")
  left=[ rect["x"], 0 ].max; right=[ rect["x"]+rect["width"], viewport["width"] ].min
  top=[ rect["y"], 0 ].max; bottom=[ rect["y"]+rect["height"], viewport["height"] ].min
  raise "Canvas not visibly drawable" unless right-left>80 && bottom-top>80
  x1=(left+(right-left)*0.25).round; x2=(left+(right-left)*0.5).round; y=(top+(bottom-top)*0.5).round
  driver.action.move_to_location(x1, y).pointer_down(:left).move_to_location(x2, y).pointer_up(:left).perform
  has_ink=lambda { driver.execute_script("const c=document.querySelector('[data-pdf-preview-target=ink]');return c&&c.getContext('2d').getImageData(0,0,c.width,c.height).data.some((v,i)=>i%4===3&&v>0)") }
  BrowserProof.check(stage, wait.until { has_ink.call })
  wait.until { element.call('[data-pdf-preview-target="draftStatus"]').text.include?("保存済み") }
  BrowserProof.check("draft_saved", true)
  driver.save_screenshot(run_root.join("handwriting.png").to_s)
  stage = "draft_restored_after_reload"
  driver.navigate.refresh
  element.call('.pdf-preview-pages[aria-busy="false"]');wait.until { has_ink.call }
  BrowserProof.check(stage, true)
  stage = "submission_cancel_keeps_ink"
  button.call("提出する");element.call("dialog[open]");button.call("いいえ")
  wait.until { driver.find_elements(css: "dialog[open]").empty? }
  BrowserProof.check(stage, has_ink.call && BrowserProof.local_uri(driver.current_url).path == preview_path)
  stage = "formal_handwritten_submission"
  button.call("提出する");element.call("dialog[open]");button.call("はい")
  wait.until { BrowserProof.local_uri(driver.current_url).path == "/student/assignments/#{aid}" }
  wait.until { driver.find_element(tag_name: "body").text.include?("5点") }
  BrowserProof.check(stage, true)
  driver.save_screenshot(run_root.join("submitted-result.png").to_s)
  driver.manage.delete_all_cookies
  teacher_login.call
  stage="teacher_review_and_excel"
  driver.navigate.to(BASE+assignment_path)
  review_link=wait.until { driver.find_elements(css: "a").find { |e| e.attribute("href").to_s.match?(%r{/assignments/#{aid}/submissions/\d+}) } }
  BrowserProof.local_uri(review_link.attribute("href"))
  review_link.click
  select=element.call('select[name^="final_judgments["]')
  Selenium::WebDriver::Support::Select.new(select).select_by(:value, "incorrect")
  button.call("保存");wait.until { driver.find_element(tag_name: "body").text.include?("0点") }
  driver.navigate.to(BASE+assignment_path+"?classroom_id=#{identity.fetch('classroom_id')}")
  export_link = wait.until { driver.find_elements(tag_name: "a").find { |e| e.text=="Excel出力" } }
  BrowserProof.local_uri(export_link.attribute("href"))
  export_link.click
  xlsx=wait.until { Dir.glob(downloads.join("*.xlsx").to_s).first }
  xml=nil;Zip::File.open(xlsx) { |z| xml=z.read("xl/worksheets/sheet1.xml") }
  document=REXML::Document.new(xml)
  score=REXML::XPath.first(document, "//*[local-name()='c' and @r='C2']/*[local-name()='v']")
  BrowserProof.check(stage, score&.text=="0")
  puts JSON.generate(outcome: "PASS", scope: "Host Chrome sandbox enabled; actual local configured-mode browser handwriting/draft/submit/review/Excel; synthetic AI only", evidence_directory: run_root.to_s, mode: MODE, certificate_scope: (MODE == "check" ? "Exact leaf preflight + session public-key exception" : "none"), assignment_id: aid.to_i)
rescue StandardError => error
  driver&.save_screenshot(run_root.join("failure.png").to_s) rescue nil
  puts JSON.generate(outcome: "FAIL", stage: stage, error_class: error.class.name, evidence_directory: run_root.to_s)
  exit 1
ensure
  driver&.quit
end
