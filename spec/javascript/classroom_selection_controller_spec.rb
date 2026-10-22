require "spec_helper"
require "open3"

RSpec.describe "Classroom selection" do
  it "submits the existing GET form on selection changes without rewriting its selected class or filter" do
    script = <<~JAVASCRIPT
      const fs = require("node:fs");
      const vm = require("node:vm");
      const assert = require("node:assert/strict");
      const source = fs.readFileSync(process.argv[1], "utf8")
        .replace(/^import .*$/m, "")
        .replace("export default class", "class ClassroomSelectionController");
      const controller = vm.runInNewContext(source + "; new ClassroomSelectionController()", { Controller: class {} });
      const requests = [];
      controller.element = {
        method: "get", classroom_id: "all", filter: "needs_review",
        requestSubmit() { requests.push([this.method, this.classroom_id, this.filter]); }
      };
      controller.element.classroom_id = "2";
      controller.submit();
      controller.element.classroom_id = "all";
      controller.submit();
      assert.deepEqual(requests, [["get", "2", "needs_review"], ["get", "all", "needs_review"]]);
    JAVASCRIPT
    path = File.expand_path("../../app/javascript/controllers/classroom_selection_controller.js", __dir__)
    stdout, stderr, status = Open3.capture3("node", "-e", script, path)
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
