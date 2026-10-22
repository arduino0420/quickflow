require "spec_helper"
require "open3"

RSpec.describe "PDF completed ink cache" do
  it "avoids replaying completed paths, ignores duplicate ends and retains PDF coordinates after zoom" do
    script = <<~JAVASCRIPT
      import fs from 'node:fs';
      import assert from 'node:assert/strict';
      const source = fs.readFileSync(process.argv[1], 'utf8');
      const { default: PdfInk } = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
      const calls = [];
      const context = new Proxy({}, {
        get: (_, name) => (...args) => calls.push([name, ...args]),
        set: (_, name, value) => { calls.push(['set', name, value]); return true; }
      });
      let rect = { left: 10, top: 20, width: 400, height: 600 };
      const canvas = { getContext: () => context, getBoundingClientRect: () => rect };
      const viewport = scale => ({ width: 200 * scale, height: 300 * scale, scale, transform: [scale,0,0,-scale,0,300*scale],
        convertToPdfPoint: (x, y) => [x / scale, 300 - y / scale],
        convertToViewportPoint: (x, y) => [x * scale, (300 - y) * scale] });
      canvas.ownerDocument = {createElement: () => ({getContext: () => context})};
      const ink = new PdfInk(canvas, 1, {cache:true});
      ink.setViewport(viewport(2), 2);
      const event = (x, y, extra = {}) => ({clientX: x, clientY: y, pointerId: 1,
        pointerType: 'mouse', button: 0, buttons: 1, ...extra});
      let changes=0, redraws=0;
      const original=ink.redraw.bind(ink);
      ink.redraw=()=>{redraws++;original()}; ink.onChange=()=>changes++;
      const replayed=[];
      const paint=ink.drawStroke.bind(ink);
      ink.drawStroke=(context,stroke)=>{replayed.push(stroke.id);paint(context,stroke)};
      for (let i=0;i<30;i++) {
        const previous=replayed.length;
        ink.start(event(110,220,{pointerType:'pen',timeStamp:i*2}));
        ink.move(event(150,260,{pointerType:'pen'})); ink.redraw();
        ink.end(event(170,280,{type:'pointerup',buttons:0,timeStamp:i*2+1}));
        assert(replayed.slice(previous).every(id=>id===i+1),'old strokes must never be replayed during input');
        const count=redraws;
        ink.end(event(170,280,{type:'lostpointercapture'})); ink.end();
        assert.equal(redraws,count,'duplicate/idle end must not redraw');
        assert.equal(changes,i+1);
      }
      const saved=JSON.stringify([...ink.pages]);
      rect={left:40,top:-500,width:800,height:1200};
      assert.deepEqual(ink.point(event(240,-100)),[50,200],'browser zoom must map to the original PDF point');
      ink.setViewport(viewport(2),2);
      assert.equal(JSON.stringify([...ink.pages]),saved);
      assert.equal(ink.cachedCount,30);
      ink.pages.set(1,structuredClone(ink.pages.get(1)));
      ink.redraw(); assert.equal(ink.cachedCount,30,'restored array must rebuild the cache');
      ink.setTool('eraser'); ink.setEraserSize('large');
      ink.start(event(240,-100)); assert.equal(ink.stroke.width,18); ink.end();
      assert.equal(changes,31);
      ink.releaseCache(); assert.equal(ink.cache.width,0); assert.equal(ink.cache.height,0);
      ink.redraw(); assert.equal(ink.cachedCount,31);
      assert.equal(changes,31,'cache rebuild must never notify autosave');
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_ink.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
