# QuickFlow

中学校数学の「式の計算」の小テストを、PDF配信から手書き解答・採点・成績出力まで支援するRailsアプリです。教師の採点・転記負担と、生徒への返却の遅れを減らすことを目指します。普段のPDF教材を使い、AIの判定と教師の最終判定を分け、判読が難しい答案を「要確認」として残す点が特徴です。

![教師の成績一覧・答案確認・生徒のPDF手書き画面（架空データ）](docs/implementation/issue95-evidence/flow-390.jpg)

画像は[Issue #95の実Chrome監査](docs/implementation/issue95_screen_audit.md)で撮影した架空データです。長文・空状態の試験を含み、AIの実実行結果や本番画面ではありません。現行ビューと導線を照合して再利用しています。

## 現在の実装と検証範囲

機能の照合基準は [main@cd97d361](https://github.com/arduino0420/quickflow/commit/cd97d361eb18b74b85275730e36c300ee47f17d9)（2026-10-22）。[main CI 39756657910](https://github.com/arduino0420/quickflow/actions/runs/39756657910)はtest・lint・scan_ruby・scan_jsが成功、RSpec 1,839件・失敗0件です。これは提出時点の公開動作や卒業合格を保証するものではありません。最終レビュー前にmain `aa52ab591f5b39c0dbc923a44ac419c9aff102c0`（#39のthruster lock更新のみ）を通常mergeで統合しました。本ドキュメントPRの最終head CIはPRのChecksで別途確認します。

ゲストの技術実装は完了していますが、**外部公開は未実施**です。既存AWS環境の配備コミット・URL・現在の健康状態はこの作業では確認していません。EC2/Caddyによる既存環境と、未配備のmain・独立デモprofileを同一視しません。[本番確認 #99](https://github.com/arduino0420/quickflow/issues/99)・[運用監査 #51](https://github.com/arduino0420/quickflow/issues/51)で提出用URL、HTTPS、`/up`、ログイン画面、DB/PDFのバックアップと復元、ワーカー監視の実証が必要です。`/up`はRails起動確認であり、AI・DB・キュー全体の健全性を保証しません。

## ロール別の利用方法

| ロール・入口 | 主な操作 |
| --- | --- |
| 教師 `/login` | 教師IDとパスワードでログイン。PDF・点数・配信先クラスを登録し、成績一覧→答案詳細でAI判定を確認/修正。得点は再計算され、単一/全配信クラスのExcelを出力。小テスト名変更・所有する小テスト削除、担当クラスの生徒登録も可能 |
| 生徒 `/student/login` | 学校コード・学年・クラス・出席番号・パスワードでログイン。未提出小テスト→PDFへ手書き→自動保存→「提出する」→採点結果を確認。通常の選択肢は1〜3年・1〜10組・1〜40番 |
| 管理者 `/admin/login` | 管理者IDとパスワードでログイン。自校の教師登録/担当・パスワード変更、生徒一覧/登録/所属編集/パスワード再設定/条件付き削除。重要な生徒操作は確認と管理者再認証が必要 |

公開サインアップはありません。教師/管理者の初期登録は所属と権限を確認した運用担当者が行います。学校コードだけで所属を証明できません。管理者15文字以上、教師は英字と数字を含む半角英数字10文字以上（各72バイト以下）、生徒は半角数字8桁で、弱い反復・語句/連番を拒否します。登録入口/運用タスクとパスワード変更で適用し、既存パスワードの一括変更はしません。パスワード変更後の旧セッションは次の認証確認で失効します。[登録・移行・削除の詳細と安全手順](docs/implementation/operations_details.md)を参照してください。

PDFは複数ページ・黒ペン/消しゴムに対応し、下書きは再ログイン後も復元します。自動保存だけでは正式提出になりません。未保存の筆跡は通信断のまま画面を閉じると失われる場合があります。従来PDFアップロードも詳細画面に残ります。答案PDFは25MiB、提出HTTP本文は32MiBまでです。

AIは「正解・不正解・要確認」を保存し、教師が修正できます。要確認は得点に加算せず、技術的失敗は採点完了と区別します。教師の採点再開ボタンは既定OFFで、世代・PDF・保存結果・未完了Jobを確認する運用条件があります。[採点・復旧・外部ファイル保持の詳細](docs/implementation/operations_details.md)を確認してください。#47/#48等の進行中の変更を完了済みとは扱いません。

### 閲覧専用ゲスト

対応する隔離デモで入口を有効にすると、ホームの管理者/教師/生徒ゲストボタンから開始できます（`POST /guest/:role`、通常環境はOFF）。15分で期限切れとなり、切替/ログアウトで旧cookieを失効します。架空の登録済みデータだけを閲覧し、教師は成績/Excel/答案、生徒は自分の課題/教材/結果、管理者は自校一覧を確認できます。登録・編集・削除・手書き提出・AI呼出し・Job実行は許可しません。手書きや実AIを体験できる公開デモという案内ではありません。

[初期test profileの履歴](docs/implementation/issue93_read_only_guest.md)と[production-mode profile・公開前条件](docs/implementation/issue93_production_demo.md)を参照してください。testサーバーをインターネットへ公開しないでください。実公開のDNS/TLS、OSによる読み取り専用mount、proxy/egress制御、公開Chromeの確認は未実施です。12業務表と正規添付の初期データ検証と、全物理表に5行あるという主張は異なります。

## 技術構成

Ruby **4.0.6**（`.ruby-version`）、Rails **8.1.4**（`Gemfile.lock`）、PostgreSQL（開発基準18.6）、Puma、Active Record/Active Storage、Hotwire/Importmap、PDF.js/pdf-lib、OpenAI SDK、caxlsx、Solid Queue/Cache/Cableを使用します。DockerfileとKamal設定、GitHub Actions CIがあります。AWS EC2/Caddyは既存配備側の構成であり、リポジトリのKamal設定をそのまま実稼働設定とは扱いません。公開設定の確定・確認は#51/#99の範囲です。

## ローカル起動とテスト

Ruby 4.0.6、Bundler、PostgreSQLと開発ヘッダー、libvipsを用意します。System SpecにはChrome/Chromiumと対応Selenium driver（Selenium Manager利用時は取得可能なネットワーク）が必要です。既存DBと共有しない新しいclone・専用DB/Storageを使ってください。通常の開発は`storage/`、テストはclone内`tmp/storage/`です。

```bash
git clone https://github.com/arduino0420/quickflow.git
cd quickflow
bundle install
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

テストは破棄可能な専用DBを使います。開発DBと同じURLを使わないでください。

```bash
export RAILS_ENV=test
export DATABASE_URL=postgresql://127.0.0.1:5432/quickflow_local_test
bin/rails db:create
# 上のrunnerと同じ方法で実接続が専用test DBであることを確認
bin/rails runner 'c = ActiveRecord::Base.connection; puts [Rails.env, c.select_value("SELECT current_database()"), c.select_value("SELECT inet_server_addr()"), c.select_value("SELECT inet_server_port()")].inspect'
bin/rails db:test:prepare
bundle exec rspec
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
```

RSpecでは実OpenAIクライアントを禁止し、stubを使用します。実APIキーは不要です。demo/load専用の`QUICKFLOW_DEMO_*`、`QUICKFLOW_GUEST_LOGIN`、`QUICKFLOW_HTTP_LOAD_RUN_ID`等を通常テストに引き継がないでください。CIの実行コマンドとOS依存パッケージは[workflow](.github/workflows/ci.yml)が基準です。モデル/リクエストだけなら`bundle exec rspec spec/models spec/requests`でも実行できます。

## データ保護・運用と設計資料

DBと添付PDFは別々に保存されるため、整合したバックアップ・復元確認が必要です。公開環境の保存期間・復元手順の確定は#51で保留しています。小テストのDB削除と物理PDFの非同期削除、外部OpenAIの3600秒File期限/非同期cleanupは別のライフサイクルです。404だけでは外部削除済みを保証せず、`store: false`も保持ゼロを保証しません。[監視・個別再確認・安全な復旧手順](docs/implementation/operations_details.md)を省略せず参照してください。

- [チェックシート](https://docs.google.com/spreadsheets/d/1G-4Q3SS79nOKc3IJGaaYNftkwM0XktCnIgPAiMZ-1ug/edit#gid=1475280975) / [カタログ](https://docs.google.com/spreadsheets/d/1G-4Q3SS79nOKc3IJGaaYNftkwM0XktCnIgPAiMZ-1ug/edit#gid=0) / [テーブル定義](https://docs.google.com/spreadsheets/d/1G-4Q3SS79nOKc3IJGaaYNftkwM0XktCnIgPAiMZ-1ug/edit#gid=524149616)
- [ワイヤーフレーム](https://whimsical.com/Lj1FAP2VsasTMNMjFAfDb4) / [ER図](docs/er_diagram.png) / [画面遷移図](docs/screen_transition.png)
- [画面・架空スクリーンショット監査](docs/implementation/issue95_screen_audit.md) / [Model Spec監査](docs/implementation/issue98_model_spec_audit.md) / [認証System監査](docs/implementation/issue96_authentication_system_audit.md) / [CRUD System監査](docs/implementation/issue97_crud_system_audit.md)
- [推奨品質監査 #104](docs/implementation/issue104_quality_audit.md) / [Phase F当時のREADME記録](docs/implementation/readme_history.md)

設計画像と外部設計資料はschema安定後の#101/#102で照合・更新します。この作業では外部資料を編集せず、現行schemaに完全同期したとは宣言しません。Windows/Chromebook実機、実通信断、実答案サイズ分布、実AIの数学的正確性、公開環境での主要フロー確認は別途必要です。
