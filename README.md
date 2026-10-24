# QuickFlow

中学校数学の小テストを、PDF教材の配信から手書き解答・採点・成績出力まで支援するRailsアプリです。教師の採点や転記の負担を減らし、生徒へ結果を返すまでの時間を短くすることを目指しています。

AIによる判定をそのまま確定せず、読みにくい答案は「要確認」として残し、教師が最終判定を確認・修正できる設計です。

**[公開アプリ](https://13-231-93-159.sslip.io/) · [閲覧専用ゲスト](https://qfd-4c18332acca47671.13-231-93-159.sslip.io/) · [必須39項目の対応表](docs/implementation/issue103_submission_evidence.md)**

![QuickFlowの公開トップ。教師・生徒のログインと閲覧専用ゲストの入口](docs/screenshots/home.jpg)

## 主な機能

| 利用者 | できること |
| --- | --- |
| 教師 | PDF教材の配信、答案とAI判定の確認、最終判定の修正、得点集計、クラス別のExcel出力 |
| 生徒 | 配信されたPDFへの手書き、下書きの自動保存・復元、正式提出、答案と採点結果の確認 |
| 管理者 | 自校の教師・生徒の登録や所属管理、パスワード再設定、条件を満たす生徒の削除 |

学校・担当クラス・配信先・作成者に応じてアクセスを制限します。公開サインアップはなく、教師・管理者の初期登録は運用担当者が行います。通常の入口は教師 `/login`、生徒 `/student/login`、管理者 `/admin/login` です。[登録・認証・管理操作の詳細](docs/implementation/operations_details.md)を参照してください。

## ゲストで画面を見る

公開トップの「ゲストとしてログインする」から、管理者・教師・生徒の役割を選べます。パスワードの入力は不要です。

- 学校本番とは別のDB・保存領域を使う、架空データ専用の閲覧環境です。
- 成績一覧、答案PDF、採点結果、管理画面を確認できます。
- 登録・編集・削除・手書き・提出・実AI採点はできません。画面の判定と得点は用意したサンプルです。
- セッションは15分で終了します。役割の切替やログアウトで以前のセッションは失効します。

ゲストは通常アカウントの代わりではありません。実生徒のデータや学校用の認証情報を入力しないでください。[分離構成と運用条件](docs/implementation/issue51_predeployment_runbook.md#公開guest評価導線同一server架空データ専用)を公開記録にまとめています。

## 使い方と画面

トップは配備後の `f22a4c8`、教師成績・答案・生徒結果は表示内容が同じ前版 `4667c7ca` の実画面です（2026-10-24 UTC）。学校・アカウント・得点は公開guest用のサンプルで、教材・答案PDFは利用者が公開を承認したものです。判定と70点は手動の表示例で、実AIの実行結果ではありません。画面の文言や値を画像編集で差し替えていません。教師答案・生徒結果は、同日の追加撮影で 提供された答案PDF の実描画を確認した画面です。

検証中に埋込みPDFが白く写る場面もありましたが、所有者は現行版の教師・生徒の両画面で表示を確認したと報告しています。原因の特定や、すべての環境での表示を保証するものではありません。

### 1. 教師がPDF教材を配信し、成績を確認する

通常利用では、PDF教材・1問の点数・配信先クラスを確認して小テストを配信します。正答生成は非同期で進むため、状態を確認しながら待ちます。成績一覧では、採点済みの得点と未提出を区別できます。

![教師guestの小テスト詳細と成績一覧。手動表示例70点と未提出、Excel出力の入口](docs/screenshots/teacher-grades.jpg)

この画像は閲覧専用guestです。成績の閲覧とExcel出力を利用できますが、通常教師の配信・編集操作はできません。

### 2. 教師が答案と判定を見比べる

答案PDFと問題ごとの結果を並べて確認できます。通常利用では、教師が最終判定を修正すると得点が再計算され、配信クラスを選んでExcelを出力できます。

![現行4667c7ca：教師guestのサンプル答案PDFと手動表示例70点](docs/screenshots/teacher-answer.jpg)

この教師答案画像は現行 `4667c7ca` の公開guestを標準Chromeで撮影したものです。答案の氏名欄は空で、表示される学校・出席番号は架空データです。PDF内の手書きと手動表示例70点を実際に確認しました。画面をスクロールした位置の撮影で、上部のguest注意表示は画像外です。実AIの実行や通常教師の判定変更を検証する画像ではありません。

### 3. 生徒が答案と結果を確認する

通常利用の流れは「PDFに手書き → 保存状態を確認 →『提出する』で正式提出 → 採点結果を確認」です。自動保存だけでは提出されません。採点では「正解・不正解・要確認」を区別し、要確認は得点に加算しません。

![標準Chromeで表示した生徒guestの答案PDFと採点結果。手動表示例70点と判定表示。撮影時に埋込みPDFが描画された実画面](docs/screenshots/student-result.jpg)

手書きの編集画面は閲覧専用guestでは操作できません。[過去の合成入力試験画像（黒い線）](docs/implementation/issue99-evidence/02-student-saved-handwriting.png)と[保存・再読込の検証記録](docs/implementation/issue103_submission_evidence.md)を別に残しています。この旧画像は試験用タイトルと黒い線を示すもので、保存状態の表示は撮影範囲外です。保存・復元の成立は検証記録を参照し、現在の編集画面を撮り直した画像とは区別してください。

### 利用時の注意

- 黒ペン・消しゴムと複数ページに対応します。通信断で未保存のまま画面を閉じると、筆跡が失われる場合があります。画面を閉じず、復旧後の保存状態を確認してください。
- 従来のPDFアップロードも利用できます。答案PDFは25MiB、提出HTTP本文は32MiBまでです。暗号化PDFの手書きexportには対応していません。
- AIは教師の判断を補助します。誤判定や読み取りの不確かさを前提に、答案と結果を確認してください。技術的な失敗は採点完了と区別します。
- 採点失敗や停止の疑いがある場合は、教師から運用担当者へ連絡します。経過時間だけで再実行したり、queueやPDFを削除したりしないでください。

[採点の復旧・外部AIへの送信と保持・管理操作の注意](docs/implementation/operations_details.md)を参照してください。パスワードの条件、登録方法、再認証・削除の手順も同文書にまとめています。

## 技術構成

| 領域 | 使用技術 |
| --- | --- |
| アプリケーション | Ruby 4.0.6 / Rails 8.1.4 / Puma / Hotwire・Importmap |
| データ・非同期処理 | PostgreSQL（開発基準18.6）、Active Record・Active Storage、Solid Queue・Cache・Cable |
| PDF・成績 | PDF.js / pdf-lib / qpdf 12.4.2 / caxlsx |
| AI連携 | OpenAI SDK（読取・正答生成・判定支援） |
| 配備・品質確認 | Docker / AWS EC2・Caddy / GitHub Actions・RSpec |

AI処理には永続要求台帳とclaimによる重複・競合対策を用い、教師の最終判定を保持します。構成と根拠は[設計資料](docs/design/README.md)と[実装・試験の対応表](docs/implementation/issue103_submission_evidence.md)を参照してください。リポジトリのKamal設定を、そのまま実稼働設定とみなさないでください。

PDFの事前確認にはqpdf 12.4.2を使います。ローカル起動・テスト前に `bin/install-qpdf` を実行してください（curl/unzipが必要）。公式配布物のSHA-256を検証し、`vendor/qpdf` 内だけに配置します。[PDFの受入条件・実行上限](docs/implementation/operations_details.md#pdf読み取り事前確認issue-48)を確認してください。

## 検証状況

- 通常サイトとguestの稼働sourceは [f22a4c8](https://github.com/arduino0420/quickflow/commit/f22a4c8aa6076fc9cb874a14058fd25780860edf)。[配備版CI40061706662](https://github.com/arduino0420/quickflow/actions/runs/40061706662)は4ジョブ成功、RSpec 2,054件・失敗0件です。文書更新のheadと稼働sourceは区別しています。
- TLS・Secure cookie、DB/PDF保全と隔離復元、worker・queue、限定した公開/guestフローを確認し、[運用監査 #51](https://github.com/arduino0420/quickflow/issues/51)と[限定フロー検証 #99](https://github.com/arduino0420/quickflow/issues/99)に完了根拠を記録しました。`/up` は起動確認であり、AI・DB・queue全体の健全性を保証しません。
- 通常の実AI配信・提出・採点、および新版の手書き・保存の成功は所有者からの報告です。担当者によるLenovo実機の独立検証、すべての端末・PDF・実通信障害、AIの数学的正確性を保証するものではありません。
- 今回の撮影では閲覧だけを行い、実生徒データの変更、答案提出、AI実行はしていません。旧表示試験用の長文画像や失敗履歴は、[検証資料](docs/implementation/issue103_submission_evidence.md)に残しています。

提出準備は[39項目の対応表](docs/implementation/issue103_submission_evidence.md)に集約しています。技術的な確認と、本人によるDPro再投稿・メンター通知・最終提出、学校側の受入判定は分けています。

## ローカル起動とテスト

Ruby 4.0.6、Bundler、PostgreSQLと開発ヘッダー、libvipsを用意します。System SpecにはChrome/Chromiumと対応Selenium driver（Selenium Manager利用時は取得可能なネットワーク）が必要です。既存DBと共有しない新しいclone・専用DB/Storageを使ってください。通常の開発は`storage/`、テストはclone内`tmp/storage/`です。

```bash
git clone https://github.com/arduino0420/quickflow.git
cd quickflow
bundle install
bin/install-qpdf
export RAILS_ENV=development
export DATABASE_URL=postgresql://127.0.0.1:5432/quickflow_local_development
# 専用DB名・接続先であることを確認してから作成
bin/rails db:create
bin/rails runner 'c = ActiveRecord::Base.connection; puts [Rails.env, c.select_value("SELECT current_database()"), c.select_value("SELECT inet_server_addr()"), c.select_value("SELECT inet_server_port()")].inspect'
# 上の実接続が意図した専用DBの場合のみ
bin/rails db:migrate
bin/rails server -b 127.0.0.1
```

`http://127.0.0.1:3000`へアクセスします。接続URLは自身の専用DBに合わせ、パスワードを履歴やリポジトリに残さないでください。`PRIMARY_DATABASE_URL`等の接続上書きが設定されている場合は取り除くか同じ専用接続先に揃え、Railsの実接続を確認します。新規DBは空です。通常の`db:seed`はコメントのみでデモ/初期アカウントを作りません。**既存DBにreset/drop/demo seedを実行しないでください。** 架空デモは[専用の新規クラスタを使う手順](docs/implementation/issue92_safe_demo_seed.md)だけで作成します。

通常の開発で実AIを利用する場合のみ、運用者から自分の環境用の秘密値を安全に受け取り、`bin/rails credentials:edit`で`openai.api_key`へ保存します。復号には対応する`RAILS_MASTER_KEY`または非公開のmaster keyが必要です。値をREADME・Issue・ログに貼らないでください。`OPENAI_MODEL`、`OPENAI_ANSWER_READING_MODEL`、`OPENAI_QUESTION_GENERATION_MODEL`、`OPENAI_ANSWER_GRADING_MODEL`と`OPENAI_TIMEOUT_SECONDS`が任意設定です。既定モデル名はソース上`gpt-6-astra`、待ち時間120秒で、利用可否・料金の保証ではありません。実送信・課金を伴う確認は別途承認が必要です。通常productionの`QUICKFLOW_DATABASE_PASSWORD`やdemo専用秘密値は[profile手順](docs/implementation/issue93_production_demo.md)に従って管理し、開発/テストへ持ち込みません。

全件/requestsテストにはDB名`quickflow_test`を要求する安全ガードがあります。名前を変えたりガードを外したりせず、**毎回新しい専用PostgreSQLクラスタ**を作り、既存の`quickflow_test`とは物理的に隔離します。PostgreSQL 18の`pg_config`・`initdb`・`pg_ctl`・`createdb`がPATHから使えることを確認し、demo/load専用環境変数や本番秘密値を引き継がない専用ターミナルで、次のブロック全体を実行します。通常の開発サーバーとテストを同じcloneで同時に動かさないでください。

```bash
(
set -eu
export RAILS_ENV=test
unset QUICKFLOW_DEMO_PROFILE QUICKFLOW_GUEST_LOGIN QUICKFLOW_HTTP_LOAD_RUN_ID SOLID_QUEUE_IN_PUMA
QF_PG_BIN="$(pg_config --bindir)"
export QF_TEST_ROOT="$(mktemp -d /tmp/qf-test.XXXXXX)"
export QF_TEST_PORT=57519
mkdir "$QF_TEST_ROOT/socket"
# 失敗時も今回作ったクラスタだけを停止。失敗後にschema準備へ進まない
trap 'if test -f "$QF_TEST_ROOT/data/postmaster.pid"; then "$QF_PG_BIN/pg_ctl" -D "$QF_TEST_ROOT/data" -m fast -w stop; fi' EXIT
"$QF_PG_BIN/initdb" -D "$QF_TEST_ROOT/data" -U qf_test_owner --locale=C --encoding=UTF8 --auth-local=trust --auth-host=trust
# ポート使用中なら起動は失敗する。既存サービスを停止せず、別の未使用ポートで新規クラスタを作る
"$QF_PG_BIN/pg_ctl" -D "$QF_TEST_ROOT/data" -l "$QF_TEST_ROOT/postgres.log" \
  -o "-h 127.0.0.1 -p $QF_TEST_PORT -k $QF_TEST_ROOT/socket" -w start
unset PGHOSTADDR PGSERVICE PGSERVICEFILE PGOPTIONS PGPASSWORD
export PGHOST=127.0.0.1 PGPORT="$QF_TEST_PORT" PGUSER=qf_test_owner
export DATABASE_URL="postgresql://qf_test_owner@127.0.0.1:$QF_TEST_PORT/quickflow_test"
export PRIMARY_DATABASE_URL="$DATABASE_URL"
"$QF_PG_BIN/createdb" quickflow_test
# schema準備前にRailsの設定と実SQL接続、クラスタの実ディレクトリを照合。不一致なら終了する
bin/rails runner '
  c = ActiveRecord::Base.connection
  cfg = ActiveRecord::Base.connection_db_config.configuration_hash
  actual = [c.select_value("SELECT current_database()"), c.select_value("SELECT inet_server_addr()"),
    c.select_value("SELECT inet_server_port()").to_i, File.realpath(c.select_value("SHOW data_directory"))]
  expected = ["quickflow_test", "127.0.0.1", Integer(ENV.fetch("QF_TEST_PORT")), File.realpath(File.join(ENV.fetch("QF_TEST_ROOT"), "data"))]
  abort "Wrong test target" unless Rails.env.test? && cfg[:database] == expected[0] &&
    cfg[:host] == expected[1] && cfg[:port].to_i == expected[2] && actual == expected
  puts actual.inspect
'
# 上の照合が成功した場合だけ続行。この新規専用DBのschemaを準備する
bin/rails db:test:prepare
bundle exec rspec
# requests/modelsだけを確認する場合も同じ隔離環境で実行する
# bundle exec rspec spec/models spec/requests
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
# 完了後はこのターミナルで作った専用クラスタだけを停止する
"$QF_PG_BIN/pg_ctl" -D "$QF_TEST_ROOT/data" -m fast -w stop
)
```

コマンドが失敗したらその先を実行せず、接続先を再確認してください。上のtrust認証は架空データだけの一時的なloopback/専用ソケット用です。実データを入れたり公開アドレスへbindしたりしません。`db:test:prepare`やRSpecは対象DBを書き換えます。`db:drop`/`db:reset`/`demo:seed`で既存DBを掃除・再利用する手順ではありません。クラスタの停止先は記録した`QF_TEST_ROOT/data`だけとし、既存サービスや他タスクのクラスタを停止しないでください。

RSpecでは実OpenAIクライアントを禁止し、stubを使用します。実APIキーは不要です。demo/load専用の`QUICKFLOW_DEMO_*`、`QUICKFLOW_GUEST_LOGIN`、`QUICKFLOW_HTTP_LOAD_RUN_ID`等を通常テストに引き継がないでください。CIの実行コマンドとOS依存パッケージは[workflow](.github/workflows/ci.yml)が基準です。モデル/リクエストだけなら`bundle exec rspec spec/models spec/requests`でも実行できます。

## 運用・設計資料

DBと添付PDFは整合したバックアップと復元確認が必要です。授業・審査前後のエラー/容量確認、重要変更前と週1回を目安にしたバックアップ、保持方針と同一サーバー保管の限界を[運用runbook](docs/implementation/issue51_predeployment_runbook.md)に記録しています。定期実行や有料監視の導入を意味しません。

DB上の削除、物理PDFの非同期削除、外部OpenAI Fileの期限・非同期cleanupは別の処理です。404や `store: false` だけで外部保持ゼロを保証しません。[外部ファイル保持と安全な復旧手順](docs/implementation/operations_details.md)を確認してください。

- [チェックシート](https://docs.google.com/spreadsheets/d/1G-4Q3SS79nOKc3IJGaaYNftkwM0XktCnIgPAiMZ-1ug/edit#gid=1475280975) / [カタログ](https://docs.google.com/spreadsheets/d/1G-4Q3SS79nOKc3IJGaaYNftkwM0XktCnIgPAiMZ-1ug/edit#gid=0) / [テーブル定義](https://docs.google.com/spreadsheets/d/1G-4Q3SS79nOKc3IJGaaYNftkwM0XktCnIgPAiMZ-1ug/edit#gid=524149616)
- [ワイヤーフレーム](https://whimsical.com/Lj1FAP2VsasTMNMjFAfDb4) / [ER図（9704b30基準）](docs/er_diagram.png) / [画面遷移図（表示実装と公開導線の照合）](docs/screen_transition.png)
- [図の編集元・実装照合・全カラムと制約](docs/design/README.md)
- [画面・架空スクリーンショット監査](docs/implementation/issue95_screen_audit.md) / [Model Spec監査](docs/implementation/issue98_model_spec_audit.md) / [認証System監査](docs/implementation/issue96_authentication_system_audit.md) / [CRUD System監査](docs/implementation/issue97_crud_system_audit.md)
- [推奨品質監査 #104](docs/implementation/issue104_quality_audit.md) / [Phase F当時のREADME記録](docs/implementation/readme_history.md)


画面遷移図はPR142の表示実装 da5763547cee と公開guest導線を照合した資料です。配備済みの版はf22a4c8で、PR142の表示変更を通常・guest双方で確認済みです。現在の公開入口はREADME冒頭と運用runbookを参照してください。ER図は図中のschema基準を維持しています。

原本ワイヤーフレームのトップと採点表示は現行仕様へ更新済みです。[差分と通知用本文](docs/implementation/issue103_submission_evidence.md)を用意しています。審査者からの閲覧確認と、DProへの修正版再投稿・変更通知・最終提出は本人が行います。

## 操作説明・発表資料

「教師が配信 → 生徒が解答・提出 → AIの補助判定を教師が確認 → 結果返却・Excel出力」の順に紹介できます。説明には上の架空画面を使い、ゲストで変更や実AI採点ができるとは案内しないでください。

既存の日本語5枚・約3分の[編集可能PPTX](docs/presentation/quickflow-overview-ja.pptx)と[閲覧用PDF](docs/presentation/quickflow-overview-ja.pdf)もあります。PDFは画像ベース、PPTXには話者ノートがあります。今回のREADME撮影とは別時点の合成資料であり、現在の公開画面はこのREADMEの画像を参照してください。導入効果・削減時間・他ICTより優れるという実証や利用者ヒアリングは行っていません。
