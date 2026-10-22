require "spec_helper"
require "open3"

RSpec.describe "Admin teacher row navigation" do
  it "opens each row's own link by pointer or keyboard without intercepting native links or selections" do
    script = <<~JAVASCRIPT
      const fs = require("node:fs");
      const vm = require("node:vm");
      const assert = require("node:assert/strict");
      const source = fs.readFileSync(process.argv[1], "utf8")
        .replace(/^import .*$/m, "")
        .replace("export default class", "class RowNavigationController");
      let selection = "";
      let prevented = 0;
      const opened = [];
      const ControllerClass = vm.runInNewContext(source + "; RowNavigationController", {
        Controller: class {}, window: { getSelection() { return selection; } }
      });
      function row(id) {
        const controller = new ControllerClass();
        controller.element = { querySelector() { throw new Error("Must use the row's explicit link target"); } };
        controller.hasLinkTarget = true;
        controller.linkTarget = { click() { opened.push(id); } };
        return controller;
      }
      const one = row("teacher-one");
      const two = row("teacher-two");
      const pointer = { button: 0, target: { closest() { return null; } } };
      one.open(pointer);
      two.open(pointer);
      assert.deepEqual(opened, ["teacher-one", "teacher-two"]);
      one.open({ ...pointer, target: { closest() { return {}; } } });
      for (const key of ["ctrlKey", "metaKey", "shiftKey", "altKey"]) one.open({ ...pointer, [key]: true });
      one.open({ ...pointer, button: 1 });
      selection = "selected teacher ID";
      one.open(pointer);
      assert.equal(opened.length, 2);
      selection = "";
      const keyboard = { target: one.element, key: "Enter", preventDefault() { prevented++; } };
      one.openWithKeyboard(keyboard);
      one.openWithKeyboard({ ...keyboard, key: " " });
      two.openWithKeyboard({ ...keyboard, target: two.element });
      assert.deepEqual(opened, ["teacher-one", "teacher-two", "teacher-one", "teacher-one", "teacher-two"]);
      assert.equal(prevented, 3);
      one.openWithKeyboard({ ...keyboard, target: { tagName: "A" } });
      one.openWithKeyboard({ ...keyboard, key: "Tab" });
      for (const key of ["ctrlKey", "metaKey", "shiftKey", "altKey"]) one.openWithKeyboard({ ...keyboard, [key]: true });
      assert.equal(prevented, 3);
      assert.equal(opened.length, 5);
    JAVASCRIPT
    path = File.expand_path("../../app/javascript/controllers/row_navigation_controller.js", __dir__)
    stdout, stderr, status = Open3.capture3("node", "-e", script, path)
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
