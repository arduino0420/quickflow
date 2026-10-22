require "spec_helper"
require "open3"
require "pathname"

RSpec.describe "Grading status refresh controller" do
  def verify_controller(assertions)
    script = <<~JAVASCRIPT
      const fs = require("node:fs");
      const vm = require("node:vm");
      const assert = require("node:assert/strict");
      const source = fs.readFileSync(process.argv[1], "utf8")
        .replace(/^import .*$/m, "")
        .replace("export default class", "class GradingStatusController");
      const timers = new Map();
      let nextTimer = 0;
      let reloads = 0;
      const frame = { src: "", reload() { reloads += 1; } };
      const window = {
        setTimeout(callback, delay) { timers.set(++nextTimer, { callback, delay }); return nextTimer; },
        clearTimeout(id) { timers.delete(id); }
      };
      const controller = vm.runInNewContext(source + "; new GradingStatusController()", { Controller: class {}, window });
      controller.element = { closest(selector) { assert.equal(selector, "turbo-frame"); return frame; } };
      controller.urlValue = "/student/assignments/1";
      #{assertions}
    JAVASCRIPT
    path = Pathname.new(__dir__).join("../../app/javascript/controllers/grading_status_controller.js").expand_path
    stdout, stderr, status = Open3.capture3("node", "-e", script, path.to_s)
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  it "waits ten seconds before loading only the status frame" do
    verify_controller <<~JAVASCRIPT
      controller.connect();
      assert.equal(timers.size, 1);
      assert.equal(frame.src, "");
      const timer = timers.get(controller.timer);
      assert.equal(timer.delay, 10000);
      timer.callback();
      assert.equal(frame.src, controller.urlValue);
      assert.equal(reloads, 0);
    JAVASCRIPT
  end

  it "reloads an existing frame once instead of navigating the page" do
    verify_controller <<~JAVASCRIPT
      frame.src = controller.urlValue;
      controller.connect();
      timers.get(controller.timer).callback();
      assert.equal(reloads, 1);
      assert.equal(timers.size, 1);
    JAVASCRIPT
  end

  it "cancels pending refreshes when the status content is replaced or disconnected" do
    verify_controller <<~JAVASCRIPT
      controller.connect();
      controller.disconnect();
      assert.equal(timers.size, 0);
      assert.equal(frame.src, "");
      assert.equal(reloads, 0);
    JAVASCRIPT
  end
end
