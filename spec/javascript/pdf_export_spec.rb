require "spec_helper"
require "open3"

RSpec.describe "PDF export snapshots" do
  it "copies every page's ordered operations independently of released canvases and subsequent edits" do
    script = <<~JAVASCRIPT
      import fs from 'node:fs';
      import assert from 'node:assert/strict';
      const source=fs.readFileSync(process.argv[1],'utf8').replace(/^import .*$/gm,'');
      const {snapshotPages,EXPORT_DPI,MAX_EXPORT_PIXELS}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
      const operations=[{id:1,tool:'pen',width:1.2,color:'#000000',points:[[10,20]]},
        {id:2,tool:'eraser',width:12,color:'#000000',points:[[10,20],[30,40]]}];
      const page={view:[20,30,220,330]};
      const states=[1,2,10].map(n=>({page,canvas:{width:0,height:0},ink:{pageNumber:n,pages:new Map([[n,structuredClone(operations)]])}}));
      const snapshot=snapshotPages(states);
      assert.equal(snapshot.length,3);
      assert.equal(snapshot[2].page,page);
      states[2].ink.pages.get(10)[0].points[0][0]=999;
      states[0].ink.pages.get(1).push({id:3});
      assert.deepEqual(snapshot.map(s=>s.operations),[operations,operations,operations]);
      assert(EXPORT_DPI>=200 && EXPORT_DPI<=300);
      // A4 RGBA temporary canvas: compare supported candidate resolutions.
      for(const dpi of [200,240,300]) {
        const pixels=Math.ceil(595*dpi/72)*Math.ceil(842*dpi/72);
        assert(pixels<MAX_EXPORT_PIXELS);
        console.log(JSON.stringify({dpi,rgbaMB:pixels*4/1e6}));
      }
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_export.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
