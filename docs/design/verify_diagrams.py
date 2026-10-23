#!/usr/bin/env python3
"""Check documentation against the exact schema and reproducible drawing source."""
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from PIL import Image
sys.dont_write_bytecode = True
root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('diagrams', root/'docs/design/build_diagrams.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)
data = json.loads((root/'docs/design/constraints.json').read_text())
assert data['baseline_commit'] == build.BASELINE
assert data['schema_sha256'] == build.digest('db/schema.rb')
assert data['routes_sha256'] == build.digest('config/routes.rb')
assert data['tables'] == build.schema(), 'Schema constraints have drifted'
tables = data['tables']
assert data['inventory'] == build.inventory(tables)
assert data['screen_baseline_commit'] == build.SCREEN_BASELINE
claim_columns = {c['name']:c for c in tables['submissions']['columns']}
for name, typ in [('processing_claim_stage','string'),('processing_claim_token','string'),('processing_claimed_at','datetime')]:
    assert claim_columns[name]['type'] == typ and claim_columns[name]['nullable']
    assert not claim_columns[name]['options']
    assert not any(f['column']==name for f in tables['submissions']['foreign_keys'])
    assert not any(name in u for u in tables['submissions']['unique_indexes'])
assert tables['classrooms']['columns'][2]['name'] == 'teacher_id'
assert tables['classrooms']['columns'][2]['nullable']
assert not any(f['column']=='material_blob_id' for f in tables['question_generation_requests']['foreign_keys'])
assert any(f['column']=='current_question_generation_request_id' for f in tables['assignments']['foreign_keys'])
for name,v in tables.items():
    cols={c['name'] for c in v['columns']}
    for f in v['foreign_keys']:
        assert f['column'] in cols
        assert f['references'].split('.')[0] in tables
    for unique in v['unique_indexes']: assert set(unique) <= cols
for doc in [root/'docs/design/README.md',root/'README.md']:
    for target in re.findall(r'\]\(([^)]+)\)',doc.read_text()):
        if re.match(r'https?://|#|mailto:',target): continue
        target=target.split('#')[0]
        assert (doc.parent/target).exists(), f'Broken link: {target}'
outputs=[root/f'docs/{n}.png' for n in ['er_diagram','screen_transition']]
outputs += [root/f'docs/design/{n}.svg' for n in ['er_diagram','screen_transition']]
outputs += [root/'docs/design/constraints.json',root/'docs/design/schema_reference.md']
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
before={str(p.relative_to(root)):sha(p) for p in outputs}
subprocess.run([sys.executable,str(root/'docs/design/build_diagrams.py')],check=True,cwd=root)
assert before == {str(p.relative_to(root)):sha(p) for p in outputs}, 'Generated files differ from source'
for name in ['er_diagram','screen_transition']:
    svg=ET.parse(root/f'docs/design/{name}.svg').getroot()
    with Image.open(root/f'docs/{name}.png') as im:
        assert im.size == (int(svg.attrib['width']),int(svg.attrib['height']))
        im.verify()
print(json.dumps({'result':'passed','baseline_commit':build.BASELINE,'schema_version':data['schema_version'],'inventory':data['inventory'],'tables':len(tables),'foreign_keys':sum(len(t['foreign_keys']) for t in tables.values()),'unique_indexes':sum(len(t['unique_indexes']) for t in tables.values()),'artifact_sha256':before},indent=2))
