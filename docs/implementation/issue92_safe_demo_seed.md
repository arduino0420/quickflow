# Issue #92: 安全な架空デモseed

通常の `db/seeds.rb` は空のままです。Rails起動、`db:prepare`、`db:seed` ではデモを作りません。
明示的な `demo:seed` タスクだけが対象です。現時点ではローカルの `RAILS_ENV=test` のみ対応します。
ゲスト入口・閲覧権限制限は #93、公開環境・AWS・実AI検証は今回の範囲外です。
このseedだけで公開・ゲストログインできるとは扱わないでください。

## 接続と隔離

新規独立clone内で、新規PostgreSQLクラスタを未使用の非5432ポートへ作成します。
既存の `~/workspace/quickflow`、既存クラスタ・DB・Storage・秘密設定は使用しません。
既存サービスを止めず、空いていないポートなら別ポートを選びます。
DB名だけで隔離は保証できません。新規クラスタの作成場所・起動引数・PIDと
`SHOW data_directory`、`current_database()`、`inet_server_addr()`、`inet_server_port()` を照合してください。
ローカルtrust認証のクラスタは127.0.0.1だけへbindし、外部公開しないでください。

以下は**新規クラスタ**向けの手順です。既存DBに印を付けて実行してはいけません。
`$PWD` が独立cloneであることを確認してください。ポートは例であり未使用確認が必要です。

```bash
export PATH="$HOME/.rbenv/versions/4.0.6/bin:/usr/local/bin:$PATH"
export RAILS_ENV=test
export QUICKFLOW_DEMO_PORT=57429
export QUICKFLOW_DEMO_DATABASE=quickflow_test
export QUICKFLOW_DEMO_ISOLATION_ID="$(ruby -rsecurerandom -e 'print SecureRandom.hex(16)')"
export DATABASE_URL="postgresql://127.0.0.1:${QUICKFLOW_DEMO_PORT}/quickflow_test"
# 新規ディレクトリに限る。既存クラスタの再利用は禁止。
initdb -D "$PWD/tmp/demo-pg-cluster" -A trust --no-locale -E UTF8
pg_ctl -D "$PWD/tmp/demo-pg-cluster" -l "$PWD/tmp/demo-postgres.log" \
  -o "-h 127.0.0.1 -p ${QUICKFLOW_DEMO_PORT} -k /tmp" start
createdb -h 127.0.0.1 -p "$QUICKFLOW_DEMO_PORT" quickflow_test
psql "$DATABASE_URL" -c 'SHOW data_directory' \
  -c 'SELECT current_database(), inet_server_addr(), inet_server_port()'
# 上記結果と新規クラスタの起動状態を照合してから次へ。
bin/rails db:migrate
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -c "COMMENT ON DATABASE quickflow_test IS 'quickflow-demo:${QUICKFLOW_DEMO_ISOLATION_ID}'"
mkdir "$PWD/tmp/demo-seed-${QUICKFLOW_DEMO_ISOLATION_ID}"
printf '%s' "$QUICKFLOW_DEMO_ISOLATION_ID" > "$PWD/tmp/demo-seed-${QUICKFLOW_DEMO_ISOLATION_ID}/.demo-isolation"
QUICKFLOW_DEMO_SEED=true bin/rails demo:seed
QUICKFLOW_DEMO_SEED=true bin/rails demo:seed
```

実行時にも実DB名・アドレス・ポート・DBコメントをSQLで読み、明示設定および
Railsの実接続設定と一致することを必須にしています。
同じ非秘密の乱数IDを持つ専用Storage印と、専用Diskサービスの絶対rootも照合します。
本番/開発、通常ポート、Unix socket、名前だけ同じDB、設定不足、共有Storage、symlinkを拒否します。
これは運用者が隔離を準備・確認するための誤操作防止策です。DBコメントや環境変数は
悪意あるDB管理者に対するアクセス制御・隔離証明にはなりません。
`config/database.yml`・production環境・credentials・依存・schemaを変更していません。

パスワードは各レコード作成時に乱数生成し、bcrypt digestだけ保存します。
平文の表示・固定公開パスワード・実アカウント複製はありません。#93で別途安全な入口が必要です。

## データ・要件の棚卸し

DPro原文は「各テーブルそれぞれ5件以上」「各モデルCRUD System Spec」であり、
内部表の除外説明はありません。下表は実装上の分類であり、卒業要件の例外承認ではありません。
**12業務表のみで文字どおり全テーブルを満たしたとは断定しません。#92はcloseしません。**

|対象表|今回の件数|安全な正規記録・残る要件解釈|
|---|---:|---|
|schools|5|架空学校DEMO1〜5。学校コードだけを保持|
|admins|5|各校管理者。既存モデルの作成検証|
|teachers|5|各校教師。IDは学校ごとに一意|
|classrooms|5|各校1年1組|
|students|10|各校提出済み1人、未提出下書き1人|
|teacher_classrooms|5|同校の正規担当関連|
|assignments|5|架空サンプルと明示。各教師1課題|
|assignment_classrooms|5|同校への配信関連|
|questions|5|各課題1問、採点JSONに教材Blob ID|
|submissions|5|完了サンプル、読取JSON・答案PDF付き|
|grading_results|5|架空採点、モデル名demo-sample-no-ai。実AIの結果ではない|
|answer_drafts|5|未提出生徒。実教材fingerprint、1ページの有効な黒線|
|active_storage_blobs|10|正規PDF添付から作成。教材5・答案5|
|active_storage_attachments|10|正規has_one_attachedを使用|
|authentication_attempt_buckets|0|正規の認証試行なら記録できるが期限付きHMAC制限情報。件数目的で失敗ログインや制限状態を作らない。メンターに適用範囲を確認|
|active_storage_variant_records|0|PDFのプレビュー/変換が必要な実フローでのみ作成。件数目的の変換・偽variationを作らない。適用範囲確認が必要|
|solid_cache_entries|作成しない|別cache DB。実cache利用からのみ。保持期間と件数要件の適用範囲確認|
|solid_cable_messages|作成しない|別cable DB。実broadcastからのみ。架空メッセージを直接INSERTしない。適用範囲確認|
|solid_queue_jobs|作成しない|別queue DB。正規enqueueからのみ。実AI起動禁止との整合を確認|
|solid_queue_ready_executions / scheduled_executions / claimed_executions / blocked_executions / failed_executions（各solid_queue_接頭辞）|作成しない|正規Job生命周期のみ。失敗・実行中・待機状態を偽造しない|
|solid_queue_processes / pauses / semaphores（各solid_queue_接頭辞）|作成しない|実ワーカー・制限・運用状態のみ。件数目的の状態は危険|
|solid_queue_recurring_tasks / recurring_executions（各solid_queue_接頭辞）|作成しない|正規定期実行の実態が必要。定期AI実行は追加しない|
|solid_queue_batches / batch_executions（各solid_queue_接頭辞）|作成しない|実batchの生命周期が必要。件数目的で追加しない|
|schema_migrations / ar_internal_metadata|Rails管理|schema.rb外の基盤表。migration履歴・環境識別を捏造しない。要件適用範囲確認|

全schemaは `db/schema.rb`・`queue_schema.rb`・`cache_schema.rb`・`cable_schema.rb` を確認しました。
内部表のCRUD画面・削除操作を追加しません。今回のRSpecはseedの整合性・拒否・再実行性の検証であり、
「各モデルCRUD System Spec」を充足したとは主張しません。メンターへの対象範囲確認が残ります。

## 再実行・失敗・並行実行

初回は全業務表・添付/Blob/variant・認証試行が空であることを確認し、
既存モデル・正規関連・正規添付だけで一括トランザクション保存します。
AI Controller/Job/外部APIは呼びません。PDFはxrefを含む1ページの実体を内部生成し、
目立つ `FICTIONAL DEMO SAMPLE - NO AI / NO REAL STUDENT` 表示を入れます。
既存QuestionGeneratorの保存正答検証、AnswerGraderの読取形式検証、
モデル検証、得点、fingerprint、Blob checksum付きopen/MIMEを確認します。

成功後の `.seed-manifest.json` は全対象表の全属性（ID・digest・時刻を含む）のSHA256と
Storage全ファイルのSHA256です。再実行は検証・照合のみ。既存値やパスワードを変更しません。
通常画面でデモデータが変わった場合も自動修復せず停止します。
ファイルの追加・消失・変更、DB行の追加・消失・変更は停止理由です。
manifestは非秘密のハッシュのみですがローカルに0600で保存し、リポジトリへ含めません。

Storageの排他flockと対象全表のEXCLUSIVE NOWAITロックで同時seed/書込み競合を拒否します。
通常DB処理がロック待ち・競合となる可能性があるため、デモアプリを起動せず実行してください。
ロック規約を守らないファイル直接操作まで完全に防ぐ仕組みではありません。

**DBとファイルシステムの原子的commitはできません。** upload途中失敗ならDBはロールバックしますが、
既に書かれたファイルを自動purgeしません。残存ファイルがあれば再実行を拒否します。
DB commit後〜manifest完了前に停止した場合も、既存DB/不完全manifestで停止します。
manifest書込み失敗時のDBはcommit済みの可能性があるため、成功扱いで再実行しないでください。
運用者が接続先・DB・専用Storageを調査し、状態を保存して報告します。
無関係なBlobをpurgeせず、drop/reset/削除で自動解決しません。
再検証は別の新規クラスタ/独立clone/Storageで行ってください。

全RSpecはseed実行**前の空の専用テストDB**で実行してください。
成功デモseedと全RSpecを同じDBで続けて運用しません（fixture/認証試行がデモmanifestを変えます）。
