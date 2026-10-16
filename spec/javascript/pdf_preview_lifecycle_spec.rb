require "spec_helper"
require "open3"

RSpec.describe "PDF preview rendering lifecycle" do
  it "serializes pages, rejects stale resize results and releases resources during pending rendering" do
    script = <<~JAVASCRIPT
      const fs = require('node:fs');
      const vm = require('node:vm');
      const assert = require('node:assert/strict');
      const source = fs.readFileSync(process.argv[1], 'utf8').replace(/^import .*$/gm, '')
        .replace('export default class', 'class Preview');
      const c = vm.runInNewContext(source + '; new Preview()', {
        Controller: class {}, window: { devicePixelRatio: 1, cancelAnimationFrame() {}, clearTimeout() {} }
      });
      const tick = () => new Promise(resolve => setImmediate(resolve));
      (async () => {
        c.active = true; c.session = Symbol(); c.revision = 0; c.renderQueue = Promise.resolve();
        c.containerTarget = {clientWidth: 200, setAttribute() {}};
        const pending = []; const rendered = []; let cancelled = 0; let cleaned = 0;
        c.pageStates = [1,2,3].map(number => ({
          page: {getViewport: ({scale}) => ({width:200*scale, height:300*scale}),
            render() { let resolve; const promise = new Promise(r => resolve = r);
              pending.push({number, resolve}); return {promise, cancel() {cancelled++}}; },
            cleanup() {cleaned++;}},
          canvas: {style:{}, getContext() {return {};}}, inkCanvas: {hidden:true},
          sheet: {querySelector() {return {style:{}};}},
          ink: {setViewport(viewport) {rendered.push([number, viewport.width]);}}
        }));
        c.updateCursor = () => {};
        await c.queueRender();
        assert.equal(pending.length, 0, 'resize during page discovery must not use an incomplete page budget');
        c.pagesReady = true;
        const first = c.queueRender(); await tick();
        assert.deepEqual(pending.map(p => p.number), [1], 'only one render may be in flight');
        c.containerTarget.clientWidth = 300;
        const latest = c.queueRender();
        pending[0].resolve(); await tick();
        assert.equal(rendered.length, 0, 'obsolete render cannot replace ink viewport');
        assert.equal(c.pageStates[0].canvas.hidden, true);
        assert.deepEqual(pending.map(p => p.number), [1,1]);
        pending[1].resolve(); await tick();
        assert.deepEqual(rendered, [[1,300]]);
        assert.deepEqual(pending.map(p => p.number), [1,1,2]);
        let destroyed = 0;
        c.loadingTask = {destroy() {destroyed++; return Promise.resolve();}};
        c.pdfWorker = {destroy() {destroyed++;}}; c.worker = {terminate() {destroyed++;}};
        c.disconnect();
        pending[2].resolve(); await latest; await first;
        assert.deepEqual(rendered, [[1,300]], 'late completion after navigation cannot change ink');
        assert.equal(pending.length, 3, 'page 3 must never render after disconnect');
        assert.equal(destroyed, 3); assert.equal(cleaned, 3); assert.equal(cancelled, 2);
        assert(c.pageStates.every(s => s.canvas.width === 0 && s.inkCanvas.width === 0));
      })().catch(error => { console.error(error); process.exitCode = 1; });
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
