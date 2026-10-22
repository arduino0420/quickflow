# Issue #92: 安全な架空デモseed

通常の `db/seeds.rb` は空のままです。Rails起動、`db:prepare`、`db:seed` ではデモを作りません。
明示的な `demo:seed` タスクだけが対象です。現時点ではローカルの `RAILS_ENV=test` のみ対応します。
ゲスト入口・閲覧権限制限は #93、公開環境・AWS・実AI検証は今回の範囲外です。
このseedだけで公開・ゲストログインできるとは扱わないでください。

## 接続と隔離

新規独立clone内で、新規PostgreSQLクラスタを未使用の非5432ポートへ作成します。
上のsubshellは任意の失敗で即停止します。失敗後に残った専用クラスタやファイルも自動削除せず調査します。
既存の `~/workspace/quickflow`、既存クラスタ・DB・Storage・秘密設定は使用しません。
既存サービスを止めず、空いていないポートなら別ポートを選びます。
DB名だけで隔離は保証できません。新規クラスタの作成場所・起動引数・PIDと
`SHOW data_directory`、`current_database()`、`inet_server_addr()`、`inet_server_port()` を照合してください。
ローカルtrust認証のクラスタは127.0.0.1だけへbindし、外部公開しないでください。

以下は**新規クラスタ**向けの手順です。既存DBに印を付けて実行してはいけません。
`$PWD` が独立cloneであることを確認してください。ポートは例であり未使用確認が必要です。

```bash
(
set -euo pipefail
export PATH="$HOME/.rbenv/versions/4.0.6/bin:/usr/local/bin:$PATH"
test -f AGENTS.md && test -f db/schema.rb && test -f lib/tasks/demo.rake
# 既存workspaceではなく、今回の独立cloneで実行すること。
export RAILS_ENV=test
export QUICKFLOW_DEMO_PORT="${QUICKFLOW_DEMO_PORT:-57429}"
ruby -rsocket -e '
  port = Integer(ARGV.fetch(0), 10)
  abort "Non-default unprivileged port required" unless (1024..65535).cover?(port) && port != 5432
  server = TCPServer.new("127.0.0.1", port)
  server.close
' "$QUICKFLOW_DEMO_PORT"
export QUICKFLOW_DEMO_DATABASE=quickflow_test
export QUICKFLOW_DEMO_ISOLATION_ID="$(ruby -rsecurerandom -e 'print SecureRandom.hex(16)')"
# このsubshell内だけで接続先を固定。既存のサービス設定は変更しない。
unset PGSERVICE PGSERVICEFILE PGOPTIONS PGPASSWORD PGHOSTADDR
export PGPASSFILE=/dev/null PGCONNECT_TIMEOUT=5
export PGHOST=127.0.0.1 PGPORT="$QUICKFLOW_DEMO_PORT" PGUSER="$(id -un)" PGSSLMODE=disable
export DATABASE_URL="postgresql://127.0.0.1:${PGPORT}/quickflow_test"
mkdir -p "$PWD/tmp"
cluster_dir="$(mktemp -d "$PWD/tmp/demo-pg.XXXXXXXX")"
cluster_dir="$(cd "$cluster_dir" && pwd -P)"
test -z "$(ls -A "$cluster_dir")"
initdb -D "$cluster_dir" -A trust --no-locale -E UTF8
pg_ctl -D "$cluster_dir" -l "$cluster_dir/server.log" \
  -o "-h 127.0.0.1 -p ${PGPORT} -k /tmp" -w start
pg_ctl -D "$cluster_dir" status
cluster_pid="$(head -n 1 "$cluster_dir/postmaster.pid")"
test "$(ps -p "$cluster_pid" -o uid= | tr -d ' ')" = "$(id -u)"
ruby -e 'abort "Wrong cluster owner" unless File.stat(ARGV.fetch(0)).uid == Process.uid' "$cluster_dir"
maintenance_url="postgresql://127.0.0.1:${PGPORT}/postgres"
# 全て読み取り専用。実接続先と起動した新規クラスタを機械的に照合する。
test "$(psql -X "$maintenance_url" -v ON_ERROR_STOP=1 -Atc 'SHOW data_directory')" = "$cluster_dir"
test "$(psql -X "$maintenance_url" -v ON_ERROR_STOP=1 -Atc "SELECT current_database() || '|' || host(inet_server_addr()) || '|' || inet_server_port() || '|' || session_user")" = "postgres|127.0.0.1|${PGPORT}|${PGUSER}"
local_cluster_id="$(LC_ALL=C pg_controldata "$cluster_dir" | sed -n 's/^Database system identifier: *//p')"
test -n "$local_cluster_id"
test "$(psql -X "$maintenance_url" -v ON_ERROR_STOP=1 -Atc 'SELECT system_identifier FROM pg_control_system()')" = "$local_cluster_id"
# ここまで成功した新規クラスタだけにDBを作成する。既存DBならcreatedbの失敗で即停止。
createdb --maintenance-db="$maintenance_url" quickflow_test
test "$(psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atc 'SHOW data_directory')" = "$cluster_dir"
test "$(psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 -Atc "SELECT current_database() || '|' || host(inet_server_addr()) || '|' || inet_server_port()")" = "quickflow_test|127.0.0.1|${PGPORT}"
bin/rails db:migrate
psql -X "$DATABASE_URL" -v ON_ERROR_STOP=1 \
  -c "COMMENT ON DATABASE quickflow_test IS 'quickflow-demo:${QUICKFLOW_DEMO_ISOLATION_ID}'"
mkdir "$PWD/tmp/demo-seed-${QUICKFLOW_DEMO_ISOLATION_ID}"
printf '%s' "$QUICKFLOW_DEMO_ISOLATION_ID" > "$PWD/tmp/demo-seed-${QUICKFLOW_DEMO_ISOLATION_ID}/.demo-isolation"
QUICKFLOW_DEMO_SEED=true bin/rails demo:seed
QUICKFLOW_DEMO_SEED=true bin/rails demo:seed
)
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

初回は全ユーザーschemaをカタログで列挙し、public以外のschema（空でも）や未知の表・viewを拒否します。
PostgreSQLカタログ・toastなどの予約schemaと`information_schema`は対象外ですが、
`pg_temp_N`内のユーザー一時表はshadowingも防ぐため拒否します。
`schema_migrations`/`ar_internal_metadata`はpublic内にある正規Rails内部表としてのみ許可します。
`search_path`外の表・foreign table・partitioned table・materialized viewも見逃さず、
外部表のデータは読みません。全業務表・添付/Blob/variant・認証試行が空であることを確認し、
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

## ローカル検証記録（2026-10-22）

- 全RSpec: 1,709件・失敗0件（追加途中のseed13件を含む）。
- 当初の最終seed関連RSpec: 23件・失敗0件。無効/環境/設定/実接続不一致、Storage不一致、symlink、
  未知の表、既存非デモ、既存値変更、再実行、PDF破損、部分upload失敗、manifest失敗、
  flock競合、別PG接続の表ロック競合を確認。
- RuboCop: 228ファイル・指摘0件。Brakeman: 79checks・警告0件。
- 全RSpec用は新規 `tmp/demo-pg-cluster`、127.0.0.1:57429/quickflow_test。
  実デモ用は別の新規 `tmp/demo-seed-pg-cluster`、127.0.0.1:57430/quickflow_test。
  両方とも実SQLのdata_directory・DB名・アドレス・ポートを照合。
- 実 `demo:seed` タスクを2回実行し、各回とも上表の件数。
  2回目の全行/ファイルSHA256照合が成功し、ID・password digest・時刻・checksum不変。
  全FK convalidated=true、無効な索引0件、正規PDF10個。
- 実デモ検証ではOpenAIクライアント生成/AiClient構築を例外で禁止し、ActiveJob enqueue通知を監視。
  実API呼出しなし・登録Job0件。PDF10個をGhostscriptで構文解析しexit 0。
- 実接続ガード確認でinetのtext castが`127.0.0.1/32`となることを検出。
  DB書込み前に安全に停止し、SQLの`host(inet_server_addr())`でアドレス自体を比較するよう修正後、
  上記実タスク2回と最終関連23件を再実行して成功。
- DB競合テストの初版でRails fixture接続のスレッド共有による待ちを検出。
  自分の該当テストプロセスだけを終了し、独立PG接続に修正して23件を再実行済み。
  既存サービス停止・DB削除・reset・purgeは行っていません。
- 最終headの全RSpecはGitHub CIで別途確認します。上記のローカル全RSpecと混同しません。

### 親レビュー後の追加確認

- `connection.tables` のsearch_path制限を廃止。pg_namespace/pg_classから全ユーザーschemaと
  schema-qualified関係を確認し、未知schema・表/view・ユーザー一時表を拒否します。
  システムカタログやtoastの実データは走査しません。publicの正規Rails内部表だけを許可します。
- 関連RSpecは最終26件・失敗0件。search_path外のschema内の既存行とユーザー一時表を保持して
  停止するテスト、空の未知schemaを拒否するテストを含みます。
- 上記Bash例をそのまま抜き出して`bash -n`成功。
  実行中の今回専用57430を指定すると空きポート検査がEADDRINUSEでexit 1となり、
  migration/COMMENTへ到達しません。既存デモの全行/ファイルdigest・manifest不変を再確認しました。
- 未使用57431で同じBash例を実行し、新規空ディレクトリへのinitdb、起動PID/所有者、
  maintenance接続の実endpoint/data_directory/pg_control_systemのsystem_identifier照合、
  createdb後の接続先再照合、migration、専用Storage準備、seed2回まで成功しました。
  実行した新規クラスタは`tmp/demo-pg.I7HL3FjN`です。
- 先行head `762175f` のGitHub CI run #136は全job成功。今回のレビュー修正後headは
  push後の新しいCIで確認するため、この成功を最終headの成功とは扱いません。
