require "spec_helper"
require "open3"

RSpec.describe "Grade row navigation" do
  it "opens the native answer link from any non-interactive cell, preserving native link and selection behavior" do
    script = <<~JAVASCRIPT
      const fs = require("node:fs");
      const vm = require("node:vm");
      const assert = require("node:assert/strict");
      const source = fs.readFileSync(process.argv[1], "utf8")
        .replace(/^import .*$/m, "")
        .replace("export default class", "class RowNavigationController");
      let clicks = 0;
      let selection = "";
      const controller = vm.runInNewContext(source + "; new RowNavigationController()", {
        Controller: class {}, window: { getSelection() { return selection; } }
      });
      controller.element = { querySelector(selector) {
        assert.equal(selector, ".grade-row-link");
        return { click() { clicks++; } };
      } };
      const event = { button: 0, target: { closest() { return null; } } };
      for (const cell of ["class", "attendance", "status", "score", "review"]) {
        controller.open(event);
      }
      assert.equal(clicks, 5);
      controller.open({ ...event, target: { closest() { return {}; } } });
      for (const key of ["ctrlKey", "metaKey", "shiftKey", "altKey"]) {
        controller.open({ ...event, [key]: true });
      }
      controller.open({ ...event, button: 1 });
      selection = "selected text";
      controller.open(event);
      assert.equal(clicks, 5);
      selection = "";
      controller.element.querySelector = () => null;
      controller.open(event);
    JAVASCRIPT
    path = File.expand_path("../../app/javascript/controllers/row_navigation_controller.js", __dir__)
    stdout, stderr, status = Open3.capture3("node", "-e", script, path)
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
