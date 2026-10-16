require "spec_helper"
require "open3"

RSpec.describe "PDF ink coordinates and strokes" do
  it "keeps PDF coordinates across resize, draws dots/curves, and separates interrupted input" do
    script = <<~JAVASCRIPT
      import fs from 'node:fs';
      import assert from 'node:assert/strict';
      const source = fs.readFileSync(process.argv[1], 'utf8');
      const { default: PdfInk } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
      const calls = [];
      const context = new Proxy({}, { get: (_, name) => (...args) => calls.push([name, ...args]) });
      let rect = { left: 10, top: 20, width: 400, height: 600 };
      const canvas = { getContext: () => context, getBoundingClientRect: () => rect };
      const viewport = scale => ({ width: 200 * scale, height: 300 * scale, scale, transform: [scale,0,0,-scale,0,300*scale],
        convertToPdfPoint: (x, y) => [x / scale, 300 - y / scale],
        convertToViewportPoint: (x, y) => [x * scale, (300 - y) * scale] });
      const ink = new PdfInk(canvas);
      ink.setViewport(viewport(2), 2);
      const event = (x, y, extra = {}) => ({clientX: x, clientY: y, pointerId: 1,
        pointerType: 'mouse', button: 0, buttons: 1, ...extra});
      assert.equal(ink.start(event(110, 220, {button: 2})), false);
      assert.equal(ink.start(event(110, 220, {pointerType: 'touch'})), false);
      assert.equal(ink.pages.get(1).length, 0);
      assert.equal(ink.start(event(110, 220)), true);
      assert.deepEqual(ink.stroke.points, [[50, 200]]);
      assert(calls.some(([name]) => name === 'arc'), 'a tap must draw a dot immediately');
      ink.end(event(110, 220, {type: 'pointerup', buttons: 0}));
      assert.equal(ink.pages.get(1)[0].points.length, 1);
      ink.start(event(210, 320, {pointerType: 'pen'}));
      ink.move(event(250, 360, {getCoalescedEvents: () => [event(230, 340)]}));
      ink.move(event(999, 999, {pointerId: 5}));
      ink.end(event(270, 380, {type: 'pointerup', buttons: 0}));
      assert.deepEqual(ink.pages.get(1)[1].points, [[100, 150], [110, 140], [120, 130], [130, 120]]);
      assert(calls.some(([name]) => name === 'quadraticCurveTo'), 'sampled curves must be smoothed');
      ink.start(event(310, 420));
      ink.end(event(999, 999, {type: 'pointercancel'}));
      ink.start(event(330, 440));
      ink.end(event(999, 999, {type: 'lostpointercapture'}));
      assert.equal(ink.pages.get(1).length, 4);
      assert.equal(ink.pages.get(1)[2].points.length, 1, 'cancel must not add a spurious point');
      assert.equal(ink.pages.get(1)[3].points.length, 1, 'capture loss must end the stroke');
      const saved = JSON.stringify([...ink.pages]);
      rect = {left: 40, top: -500, width: 200, height: 300};
      ink.setViewport(viewport(1), 1.5);
      assert.equal(JSON.stringify([...ink.pages]), saved, 'resize cannot change stored PDF coordinates');
      assert.deepEqual(ink.point(event(90, -400)), [50, 200], 'scroll + resize must map to same PDF point');
      assert.equal(canvas.width, 300);
      assert.equal(canvas.height, 450);
      assert(calls.some(([name, x, y]) => name === 'arc' && x === 50 && y === 100));
      ink.start(event(90, -400));
      ink.move(event(100, -390, {buttons: 0}));
      assert.equal(ink.stroke, null, 'missing mouseup must not keep drawing');
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_ink.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
