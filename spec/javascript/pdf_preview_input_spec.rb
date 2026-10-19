require "spec_helper"
require "open3"

RSpec.describe "PDF preview input isolation" do
  it "records consecutive pen strokes and cancels native actions only for the ink input" do
    script = <<~JAVASCRIPT
      const fs = require('node:fs');
      const vm = require('node:vm');
      const assert = require('node:assert/strict');
      const inkSource = fs.readFileSync(process.argv[1], 'utf8')
        .replace('export const', 'const').replace('export default class', 'class');
      const PdfInk = vm.runInNewContext(inkSource + '; PdfInk');
      const source = fs.readFileSync(process.argv[2], 'utf8').replace(/^import .*$/gm, '')
        .replace('export default class', 'class Preview');
      const scrolls = [];
      const c = vm.runInNewContext(source + '; new Preview()', {
        Controller: class {}, window: {devicePixelRatio:1, scrollBy:(...args)=>scrolls.push(args),
          requestAnimationFrame:()=>1, cancelAnimationFrame() {}}
      });
      const captures = new Set();
      const canvas = {hidden:false, getBoundingClientRect:()=>({left:0,top:0,width:200,height:300}),
        getContext:()=>new Proxy({}, {get:()=>()=>{}}),
        setPointerCapture:id=>captures.add(id), hasPointerCapture:id=>captures.has(id),
        releasePointerCapture:id=>captures.delete(id)};
      const ink = new PdfInk(canvas);
      ink.setViewport({width:200,height:300,transform:[1,0,0,1,0,0],
        convertToPdfPoint:(x,y)=>[x,y], convertToViewportPoint:(x,y)=>[x,y]}, 1);
      let changes = 0;
      ink.onChange = () => changes++;
      const state = {inkCanvas:canvas, ink, renderedWidth:200, renderedDpr:1};
      c.statesByCanvas = new WeakMap([[canvas,state]]);
      c.containerTarget = {clientWidth:200}; c.draftEditable = true;
      c.showCursor = c.showDraftStatus = () => {};
      const event = (extra={}) => ({currentTarget:canvas, pointerId:1, pointerType:'pen',
        button:0, buttons:1, clientX:20, clientY:20, cancelable:true, defaultPrevented:false,
        preventDefault() {this.defaultPrevented=true;}, ...extra});
      for (let i=0;i<10;i++) {
        const down=event({pointerId:i+1}); c.pointerDown(down);
        assert(down.defaultPrevented);
        const move=event({pointerId:i+1,clientX:40}); c.pointerMove(move);
        assert(move.defaultPrevented);
        c.pointerEnd(event({pointerId:i+1,type:'pointerup',buttons:0,clientX:50}));
        assert.equal(c.inputState,null); assert.equal(captures.size,0);
      }
      assert.equal(ink.pages.get(1).length,10);
      assert(ink.pages.get(1).every(op=>op.points.length===3));
      assert.equal(changes,10,'every completed stroke must notify autosave');
      for (const type of ['pointercancel','lostpointercapture']) {
        c.pointerDown(event()); c.pointerEnd(event({type}));
        c.pointerDown(event()); assert(c.inputState);
        c.pointerEnd(event({type:'pointerup'}));
      }
      for (const unavailable of ['draft','resize']) {
        c.draftEditable = unavailable !== 'draft';
        state.renderedWidth = unavailable === 'resize' ? 100 : 200;
        const before=ink.pages.get(1).length, down=event(); c.pointerDown(down);
        assert(down.defaultPrevented); assert.equal(ink.pages.get(1).length,before);
      }
      c.draftEditable=true; state.renderedWidth=200;
      const right=event({pointerType:'mouse',button:2}); c.pointerDown(right);
      assert.equal(right.defaultPrevented,false);
      const outside=event({currentTarget:{}}); c.pointerDown(outside);
      assert.equal(outside.defaultPrevented,false);
      const finger=event({pointerType:'touch',pointerId:90});
      const count=ink.pages.get(1).length; c.pointerDown(finger);
      const drag=event({pointerType:'touch',pointerId:90,clientY:10}); c.pointerMove(drag);
      assert.equal(finger.defaultPrevented,false); assert.equal(drag.defaultPrevented,false);
      assert.equal(JSON.stringify(scrolls),JSON.stringify([[0,10]]));
      c.pointerEnd(event({pointerType:'touch',pointerId:90,type:'pointerup'}));
      assert.equal(ink.pages.get(1).length,count);
      c.pointerDown(event());
      const unrelated=event({pointerId:99}); c.pointerMove(unrelated);
      assert.equal(unrelated.defaultPrevented,false);
      c.pointerEnd(event({type:'pointerup'}));
      for (const type of ['selectstart','contextmenu']) {
        const selection=event({type}); c.preventPageSelection(selection);
        assert(selection.defaultPrevented);
      }
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/pdf_ink.js", __dir__),
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
