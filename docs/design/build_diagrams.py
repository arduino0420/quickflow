#!/usr/bin/env python3
"""Documentation-only SVG + PNG renderer. Requires Pillow 12.0.0, no Rails/DB.
Run from repository root. SVG and PNG share the same drawing primitives.
"""
import argparse, hashlib, json, math, os, re
from pathlib import Path
from html import escape
from functools import lru_cache
@lru_cache(maxsize=16)
def font_at(size): return ImageFont.truetype(FONT,size)
from PIL import Image, ImageDraw, ImageFont
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'docs/design'
FONT = os.environ.get('DIAGRAM_FONT', '/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc')
BASELINE = '9bed9d2b6e35e89e51b8d76d1aa76df3e9f01b41'
labels = {'schools':'学校','admins':'管理者','teachers':'教師','classrooms':'クラス','students':'生徒','teacher_classrooms':'担当クラス','assignments':'小テスト・配信','assignment_classrooms':'配信先','answer_drafts':'答案下書き','questions':'設問・正答','submissions':'提出答案','grading_results':'採点結果','question_generation_requests':'正答生成要求','authentication_attempt_buckets':'認証制限・ゲスト有効期限','active_storage_attachments':'添付','active_storage_blobs':'ファイル情報','active_storage_variant_records':'派生画像'}
def digest(path): return hashlib.sha256((ROOT/path).read_bytes()).hexdigest()
def schema():
    raw=(ROOT/'db/schema.rb').read_text(); tables={}
    for name, options, body in re.findall(r'create_table "([^"]+)"(.*?) do \|t\|\n(.*?)\n  end', raw, re.S):
        pk='key_digest' if name=='authentication_attempt_buckets' else 'id'
        cols=[{'name':pk,'type':'string(64)' if pk=='key_digest' else 'bigint','nullable':False,'primary_key':True}]
        for typ,col,opts in re.findall(r'^    t\.(\w+) "([^"]+)"([^\n]*)',body,re.M):
            if typ=='index': continue
            cols.append({'name':col,'type':typ,'nullable':'null: false' not in opts,'options':opts.lstrip(', ')})
        unique=[re.findall(r'"([^"]+)"',m) for m in re.findall(r't.index \[(.*?)\].*?unique: true',body)]
        tables[name]={'label':labels[name],'columns':cols,'unique_indexes':unique,'foreign_keys':[]}
    for child,parent,opts in re.findall(r'add_foreign_key "([^"]+)", "([^"]+)"([^\n]*)',raw):
        m=re.search(r'column: "([^"]+)"',opts); col=m.group(1) if m else parent.rstrip('s')+'_id'
        tables[child]['foreign_keys'].append({'column':col,'references':parent+'.id'})
    return tables
class Canvas:
    def __init__(self,w,h,title,subtitle):
        self.w=w;self.h=h;self.im=Image.new('RGB',(w,h),'#f5f7fb');self.d=ImageDraw.Draw(self.im);self.svg=[]
        self.rect(0,0,w,h,'#f5f7fb','#f5f7fb');self.text(40,25,title,30);self.text(40,74,subtitle,18)
    def text(self,x,y,s,size=19,color='#172b46'):
        font=font_at(size); self.d.text((x,y),s,font=font,fill=color)
        self.svg.append(f'<text x="{x}" y="{y}" dominant-baseline="text-before-edge" font-size="{size}" fill="{color}">{escape(s)}</text>')
        assert self.d.textbbox((x,y),s,font=font)[2] <= self.w-15, s
    def rect(self,x,y,w,h,fill='#ffffff',stroke='#b8c7d9'):
        self.d.rectangle((x,y,x+w,y+h),fill=fill,outline=stroke,width=2)
        self.svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" fill="{fill}" stroke="{stroke}" stroke-width="2"/>')
    def card(self,x,y,w,title,lines,color='#dceafe',size=18):
        h=57+len(lines)*29;self.rect(x,y,w,h);self.rect(x,y,w,44,color);self.text(x+12,y+8,title,21)
        for i,s in enumerate(lines):
            assert self.d.textlength(s,font=font_at(size)) <= w-24, s
            self.text(x+12,y+53+i*29,s,size)
        return h
    def arrow(self,x,y,x2,y2,label=''):
        color='#456583';self.d.line((x,y,x2,y2),fill=color,width=3)
        a=math.atan2(y2-y,x2-x); pts=[(x2,y2),(x2-12*math.cos(a-.45),y2-12*math.sin(a-.45)),(x2-12*math.cos(a+.45),y2-12*math.sin(a+.45))]
        self.d.polygon(pts,fill=color);self.svg.append(f'<path d="M{x},{y} L{x2},{y2}" stroke="{color}" stroke-width="3" fill="none"/>');self.svg.append('<polygon points="'+' '.join(f'{a},{b}' for a,b in pts)+f'" fill="{color}"/>')
        if label:self.text(x+15,(y+y2)//2-12,label,17)
    def save(self,name):
        self.im.save(ROOT/f'docs/{name}.png')
        (OUT/f'{name}.svg').write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}" font-family="Hiragino Sans, Noto Sans CJK JP, sans-serif">'+''.join(self.svg)+'</svg>')
def er(t):
    c=Canvas(1660,1740,'QuickFlow ER / 関係と制約','実装基準 '+BASELINE[:12]+'  •  全カラム・型・デフォルト値は schema_reference.md / constraints.json')
    c.text(40,117,'→ は子の列から親の id への DB FK。必須 = NOT NULL、? = NULL 可。親 1 : 子 0..N（別記を除く）。',20)
    c.text(40,151,'U(...) は DB 複合 Unique。全表の主キーは id、認証制限のみ key_digest。日時列は詳細参照。',20)
    groups=[
      [('schools',['school_code 必須 / U(school_code)']),('teachers',['school_id 必須 → schools','user_id 必須 / U(user_id)','password_digest 必須']),('admins',['school_id 必須 → schools','user_id 必須 / U(user_id)','password_digest 必須'])],
      [('classrooms',['school_id 必須 → schools','teacher_id ? → teachers（旧列）','U(school_id, grade, class_number)']),('teacher_classrooms',['teacher_id 必須 → teachers','classroom_id 必須 → classrooms','U(teacher_id, classroom_id)']),('students',['classroom_id 必須 → classrooms','attendance_number 必須','U(classroom_id, attendance_number)'])],
      [('assignments',['teacher_id 必須 → teachers','published_at ?','current pointer ? → 生成要求','title / point_per_question 必須']),('assignment_classrooms',['assignment_id 必須 → assignments','classroom_id 必須 → classrooms','U(assignment_id, classroom_id)']),('answer_drafts',['student_id 必須 → students','assignment_id 必須 → assignments','U(student_id, assignment_id)','fingerprint / page_data / lock_version'])],
      [('questions',['assignment_id 必須 → assignments','U(assignment_id, position)','question_text / correct_answer 必須','生成モデル・版・日時 必須']),('submissions',['assignment_id 必須 → assignments','student_id 必須 → students','U(assignment_id, student_id)','status / submitted_at 必須','extracted_text ? / generation 必須']),('grading_results',['submission_id 必須 → submissions','question_id 必須 → questions','U(submission_id, question_id)','AI判定 必須 / 教師判定 ?','読取確度・答案・所見など NULL 可'])]
    ]
    y=205
    for row in groups:
        for i,(name,lines) in enumerate(row):c.card(40+i*540,y,510,name+' / '+labels[name],lines,size=18)
        y+=230
    c.text(40,1137,'内部処理・認証・ファイル（業務データと分離）',24)
    c.card(40,1190,650,'question_generation_requests / 正答生成要求',[
      'assignment_id 必須 → assignments','material_blob_id 必須：DB FK なし','U(assignment_id, material_blob_id, model, prompt_version)',
      'model / prompt_version / state 必須','claim_token / started_at / finished_at / failure_code ?',
      'assignments.current_question_generation_request_id は NULL 可',
      '同じ assignment の要求かはモデル検証（複合 FK なし）'], '#e8e0fa',17)
    c.card(720,1190,900,'ActiveStorage / フレームワーク',[
      'attachments.blob_id 必須 → blobs / variant_records.blob_id 必須 → blobs',
      'attachments: U(record_type, record_id, name, blob_id)',
      'blobs: U(key) / variant_records: U(blob_id, variation_digest)',
      'record_type + record_id は多態参照：業務表への DB FK なし',
      'Assignment.material_file / Submission.answer_file はモデル関連'], '#e8e0fa',18)
    c.card(720,1440,900,'authentication_attempt_buckets / 認証状態',[
      'PK key_digest (string 64) / attempts・expires_at 必須',
      '学校・利用者への FK なし。HMAC キー、認証制限・ゲスト期限に使用'], '#e8e0fa',18)
    c.text(40,1630,'モデル検証：学校一致・配信先所属・採点対象の課題一致は追加の DB FK を意味しない。',21)
    c.text(40,1670,'担当クラスは teacher_classrooms。classrooms.teacher_id の nullable FK は現行 schema に残存。',21)
    c.save('er_diagram')
def screens():
    c=Canvas(1660,1800,'QuickFlow 画面遷移 / 実装された操作','実装基準 '+BASELINE[:12]+'  •  矢印は操作または応答。箱内に実ルート／状態を併記。詳細・認可は README.md。')
    c.card(40,115,1580,'公開トップ GET /', ['教師 /login・生徒 /student/login・管理者 /admin/login は別の認証入口。公開 signup / rails_admin はない。'],size=20)
    columns=[
      ('教師',40,'#dceafe',[
       ('ログイン GET/POST /login',['ユーザーID + パスワード']),
       ('配信一覧 GET /assignments',['自分が作成した配信を表示']),
       ('一覧 → 配信登録 GET …/new',['学校内の配信先クラス・教材PDF・点数','POST /assignments → 登録画面に戻る']),
       ('一覧 → 詳細 GET /assignments/:id',['クラス切替・未提出/要確認・成績','GET edit → PATCH タイトル変更','DELETE → 一覧（作成者の範囲）']),
       ('詳細 ↔ 答案 GET …/submissions/:id',['答案表示 GET …/answer','PATCH 判定保存 → 同じ採点画面']),
       ('答案画面の条件操作「採点を再開する」',['POST …/submissions/:id/resume_grading','フラグON + failed / 停止grading候補','安全条件不成立は拒否・運用者へ確認'])]),
      ('生徒',580,'#d9f1e9',[
       ('ログイン GET/POST /student/login',['学校コード・学年・組・出席番号・PW']),
       ('一覧 GET /student/assignments',['同じ学校・所属クラスへの配信のみ']),
       ('直接手書き GET …/:id/pdf_preview',['未提出カード → PDFに解答','GET/PATCH …/:id/answer_draft 自動保存','保存再試行 / 別タブ再ログイン→再開確認']),
       ('提出 POST …/:id/submission',['下書き版・教材・提出済みを照合','応答不明時 GET submission / recovery','同じ答案を確認して結果画面へ']),
       ('詳細・結果 GET …/:id',['submitted / grading は状態を再取得','completed：答案PDF・点数・問題別結果','failed：先生へ確認（生徒の再採点なし）']),
       ('副導線：従来のPDFアップロード',['詳細の折りたたみ → PDF選択 → POST','未提出時のみ。教材DL GET …/:id/material','GET …/:id/result は詳細へリダイレクト'])]),
      ('管理者',1120,'#eee1f8',[
       ('ログイン GET/POST /admin/login',['管理者ID + パスワード']),
       ('管理トップ GET /admin',['自身の学校内のみ']),
       ('トップ ↔ 教師管理 /admin/teachers',['一覧 → new / create → 一覧','edit / update：担当クラス・PW変更','教師登録時にクラス指定・作成']),
       ('トップ ↔ 生徒管理 /admin/students',['一覧・絞込 → new / create','edit → POST confirm_update → PATCH','confirm_destroy → DELETE：1人を確認']),
       ('生徒一覧 → PW再設定',['GET …/:id/password_reset/edit', 'PATCH …/:id/password_reset','対象確認・管理者再認証','教師PW変更・生徒削除も再認証条件あり']),
       ('登録・認可の補足',['教師にも GET /students/new の登録画面', 'POST /students で担当クラスの生徒を登録','担当クラス限定（公開登録ではない）','教師の配信登録は学校内クラスを選択'])])]
    for role,x,color,items in columns:
        c.text(x,245,role,26);y=295
        for index,(title,lines) in enumerate(items):
            h=c.card(x,y,500,title,lines,color,18)
            if index == 0 or (role == '生徒' and index in (1,2,3)):
                c.arrow(x+250,y+h+3,x+250,y+h+35)
            y+=h+43
    c.text(40,1400,'共通・分岐（上からの矢印は代表導線。副導線と条件操作は必須手順ではない）',23)
    c.card(40,1450,770,'教師の成績出力 / 戻る / ログアウト',[
      '詳細 → GET /assignments/:id/export.xlsx?classroom_id=…',
      'クラスまたは all を指定。詳細↔答案、一覧↔詳細の戻り導線あり',
      '通常 DELETE logout → 各ログイン。デモはトップへ',
      '404 / 500 → GET /。認証制限 429 / 利用不可 503'],size=18)
    c.card(840,1450,780,'ゲスト：実装済み / 通常は OFF',[
      '有効な隔離デモ構成のみ POST /guest/:role（3ロール）',
      '合成データの許可された GET のみ。登録・変更・手書き不可',
      '教師Excel・答案閲覧は許可。15分期限、ログアウトで失効',
      '実装と公開デプロイは別。現在の公開ゲストURLは未確認'], '#fff0cc',18)
    c.text(40,1710,'手書きの競合・教材変更・認証切れ・保存失敗は状態別に案内。読取を新たに再実行する UI はない。',21)
    c.text(40,1750,'同じ画面の保存・確認・失敗状態を独立した製品画面として数えない。',21)
    c.save('screen_transition')
def details(t):
    data={'baseline_commit':BASELINE,'schema_sha256':digest('db/schema.rb'),'routes_sha256':digest('config/routes.rb'),'tables':t,'model_only_constraints':['same school for teacher_classrooms / assignment_classrooms','submission assignment distributed to student classroom','grading_result question belongs to submission assignment','Assignment current request belongs to same assignment'],'not_database_foreign_keys':['question_generation_requests.material_blob_id','active_storage_attachments.record_type + record_id'],'issue46_refresh':'pending: inspect merged main before final acceptance; no pending Submission claim attributes represented'}
    (OUT/'constraints.json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
    lines=['# 現行スキーマの全属性と制約','',f'基準 commit: `{BASELINE}`。`db/schema.rb` のみから生成。モデル検証とは区別する。', '', 'NULL 可は明示。`options` は型の長さ・default 等を原文で保持。業務表と ActiveStorage は同一 DB の定義。']
    for name,v in t.items():
        lines+=['',f'## {name} / {v["label"]}','','| 列 | 型 | NULL可 | options |','|---|---|---|---|']
        for col in v['columns']:lines.append(f'| {col["name"]} | {col["type"]} | {"不可" if not col["nullable"] else "可"} | {"PK" if col.get("primary_key") else col.get("options", "")} |')
        lines+=['','Unique: '+('; '.join(' + '.join(u) for u in v['unique_indexes']) or '主キー以外なし'),'','DB FK: '+('; '.join(f'{f["column"]} → {f["references"]}' for f in v['foreign_keys']) or 'なし')]
    (OUT/'schema_reference.md').write_text('\n'.join(lines)+'\n')
if __name__=='__main__':
    tables=schema();details(tables);er(tables);screens()
