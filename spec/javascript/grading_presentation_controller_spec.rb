require "spec_helper"
require "open3"
require "pathname"

RSpec.describe "Student grading presentation controller" do
  def verify_controller(assertions)
    script = <<~JAVASCRIPT
      const fs = require("node:fs");
      const vm = require("node:vm");
      const assert = require("node:assert/strict");
      const source = fs.readFileSync(process.argv[1], "utf8")
        .replace(/^import .*$/m, "")
        .replace("export default class", "class GradingPresentationController");
      const timers = new Map();
      let nextTimer = 0;
      let reduced = false;
      let currentState = "grading";
      const frame = { id: "grading-status", querySelector() { return { dataset: { gradingState: currentState } }; } };
      const element = {
        dataset: {},
        querySelector(selector) { assert.equal(selector, "[data-grading-state]"); return frame.querySelector(); },
        contains(target) { return target === frame; }
      };
      const window = {
        setTimeout(callback, delay) { timers.set(++nextTimer, { callback, delay }); return nextTimer; },
        clearTimeout(id) { timers.delete(id); },
        matchMedia(query) { assert.equal(query, "(prefers-reduced-motion: reduce)"); return { matches: reduced }; }
      };
      const controller = vm.runInNewContext(source + "; new GradingPresentationController()", { Controller: class {}, window });
      controller.element = element;
      function card(id) {
        const classes = new Set();
        const styles = new Map();
        return { id, classes, styles,
          classList: { add(name) { classes.add(name); }, remove(name) { classes.delete(name); } },
          style: { setProperty(name, value) { styles.set(name, value); }, removeProperty(name) { styles.delete(name); } }
        };
      }
      function eventFor(state, cards = []) {
        return { target: frame, detail: { newFrame: {
          querySelector() { return state ? { dataset: { gradingState: state } } : null; },
          querySelectorAll(selector) { assert.equal(selector, "[data-grading-presentation-card]"); return cards; }
        } } };
      }
      #{assertions}
    JAVASCRIPT
    path = Pathname.new(__dir__).join("../../app/javascript/controllers/grading_presentation_controller.js").expand_path
    stdout, stderr, status = Open3.capture3("node", "-e", script, path.to_s)
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  it "reveals completed cards in DOM order with short staggered starts" do
    verify_controller <<~JAVASCRIPT
      controller.connect();
      assert.equal(timers.size, 0);
      const cards = [card("question_20"), card("question_3"), card("question_9")];
      controller.beforeRender(eventFor("completed", cards));
      assert.deepEqual(cards.map(c => c.styles.get("--student-result-delay")), ["0ms", "75ms", "150ms"]);
      cards.forEach(c => assert.equal(c.classes.has("student-result-enter"), true));
      assert.equal(timers.size, 1);
      assert.equal(timers.get(controller.cleanupTimer).delay, 1600);
      timers.get(controller.cleanupTimer).callback();
      assert.equal(timers.size, 0);
      cards.forEach(c => { assert.equal(c.classes.size, 0); assert.equal(c.styles.size, 0); });
    JAVASCRIPT
  end

  it "caps the whole sequence while keeping every start in order for large quizzes" do
    verify_controller <<~JAVASCRIPT
      controller.connect();
      const cards = Array.from({ length: 100 }, (_, i) => card(i));
      controller.beforeRender(eventFor("completed", cards));
      const starts = cards.map(c => parseFloat(c.styles.get("--student-result-delay")));
      assert.equal(starts[0], 0);
      assert.ok(starts.at(-1) <= 900);
      starts.slice(1).forEach((start, i) => assert.ok(start > starts[i]));
    JAVASCRIPT
  end

  it "does not animate a completed page opened later or on reconnect" do
    verify_controller <<~JAVASCRIPT
      currentState = "completed";
      controller.connect();
      const cards = [card(1)];
      controller.beforeRender(eventFor("completed", cards));
      controller.disconnect();
      controller.connect();
      controller.beforeRender(eventFor("completed", cards));
      assert.equal(cards[0].classes.size, 0);
      assert.equal(timers.size, 0);
    JAVASCRIPT
  end

  it "animates only once including repeated or teacher-corrected completed results" do
    verify_controller <<~JAVASCRIPT
      controller.connect();
      const first = [card(1)];
      controller.beforeRender(eventFor("completed", first));
      currentState = "completed";
      controller.frameLoaded({ target: frame });
      const updated = [card(1), card(2)];
      controller.beforeRender(eventFor("completed", updated));
      first.concat(updated).forEach(c => assert.equal(c.classes.size, 0));
      controller.disconnect();
      controller.connect();
      controller.beforeRender(eventFor("completed", updated));
      assert.equal(timers.size, 0);
    JAVASCRIPT
  end

  [ "submitted", "grading" ].each do |state|
    it "waits for real completed results after #{state} refreshes" do
      verify_controller <<~JAVASCRIPT
        currentState = "#{state}";
        controller.connect();
        controller.beforeRender(eventFor("#{state}", [card(1)]));
        assert.equal(timers.size, 0);
        const cards = [card(1)];
        controller.beforeRender(eventFor("completed", cards));
        assert.equal(cards[0].classes.has("student-result-enter"), true);
      JAVASCRIPT
    end
  end

  it "does not animate on failed or missing status responses" do
    verify_controller <<~JAVASCRIPT
      for (const state of ["failed", null]) {
        controller.connect();
        controller.beforeRender(eventFor(state, [card(1)]));
        const later = [card(1)];
        controller.beforeRender(eventFor("completed", later));
        assert.equal(later[0].classes.size, 0);
        assert.equal(timers.size, 0);
      }
    JAVASCRIPT
  end

  it "respects reduced motion without hiding results or scheduling animation cleanup" do
    verify_controller <<~JAVASCRIPT
      reduced = true;
      controller.connect();
      const cards = [card(1)];
      controller.beforeRender(eventFor("completed", cards));
      assert.equal(cards[0].classes.size, 0);
      assert.equal(cards[0].styles.size, 0);
      assert.equal(timers.size, 0);
    JAVASCRIPT
  end

  it "allows empty or invalid completed results to show the server's error without animation" do
    verify_controller <<~JAVASCRIPT
      controller.connect();
      controller.beforeRender(eventFor("completed"));
      assert.equal(timers.size, 0);
      assert.equal(controller.waiting, false);
    JAVASCRIPT
  end

  it "pauses decorations on network failure and allows a later successful response" do
    verify_controller <<~JAVASCRIPT
      controller.connect();
      controller.requestFailed({ target: frame });
      assert.equal(element.dataset.gradingPresentationPaused, "true");
      assert.equal(timers.size, 0);
      controller.responseReceived({ target: frame, detail: { fetchResponse: { succeeded: true } } });
      const cards = [card(1)];
      controller.beforeRender(eventFor("completed", cards));
      assert.equal(element.dataset.gradingPresentationPaused, undefined);
      assert.equal(cards[0].classes.has("student-result-enter"), true);
    JAVASCRIPT
  end

  it "does not animate error HTTP responses even when they contain a result frame" do
    verify_controller <<~JAVASCRIPT
      controller.connect();
      controller.responseReceived({ target: frame, detail: { fetchResponse: { succeeded: false } } });
      const cards = [card(1)];
      controller.beforeRender(eventFor("completed", cards));
      assert.equal(element.dataset.gradingPresentationPaused, "true");
      assert.equal(cards[0].classes.size, 0);
      assert.equal(timers.size, 0);
    JAVASCRIPT
  end

  it "cleans active effects on disconnect and does not touch another frame or the PDF" do
    verify_controller <<~JAVASCRIPT
      controller.connect();
      const foreign = eventFor("completed", [card(1)]);
      foreign.target = { id: "grading-status" };
      controller.beforeRender(foreign);
      controller.requestFailed(foreign);
      const pdf = eventFor("completed", [card(1)]);
      pdf.target = { id: "answer-pdf" };
      controller.beforeRender(pdf);
      assert.equal(timers.size, 0);
      assert.equal(element.dataset.gradingPresentationPaused, undefined);
      const cards = [card(1)];
      controller.beforeRender(eventFor("completed", cards));
      controller.disconnect();
      assert.equal(timers.size, 0);
      assert.equal(cards[0].classes.size, 0);
      assert.equal(cards[0].styles.size, 0);
    JAVASCRIPT
  end
end
