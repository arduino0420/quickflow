# Issue #104: 推奨品質の限定監査（2026-10-22）

[Issue #104](https://github.com/arduino0420/quickflow/issues/104)は合格必須ではない推奨品質です。動作維持を優先し、このPRはREADMEと文書だけを変更します。アプリ・ルート・schema・依存・CIの変更や任意リファクタリングはありません。

初期読取はmain `cd97d361eb18b74b85275730e36c300ee47f17d9`。最終レビュー前に通常の`git fetch origin main`→`git merge --no-edit origin/main`で `aa52ab591f5b39c0dbc923a44ac419c9aff102c0` を統合しました（fast-forward、差分は#39のthruster lock更新のみ）。#47/#48等の進行中実装は完了扱いしません。変更前に対象・低リスクの文書作業であることを提示し、依頼済みの範囲内で実施しました。

## 観察と優先度

| 観察・根拠 | 深刻度・判断 |
| --- | --- |
| [routes](../../config/routes.rb)と実`bin/rails routes`（通常profile、ヘッダーを含む76行）を照合。`resources`のonly、課題→答案のネスト、単一の下書き/提出/password_resetの`resource`を使用。export/answer/resultは対象resourceのGET、resume_gradingとconfirm_updateはPOST、削除確認はGETで実削除はDELETE | 変更不要。親子IDと所有scopeを維持。URLを見栄えだけで変更しない |
| `/login`・`/student/login`・`/admin/login`と各DELETE logoutは既存ロール別セッションの入口。`result`は詳細へのredirect互換。`/guest/:role`は明示有効時のみ、production demoかtestに限定 | 変更不要。通常routes実行時のguest不在は意図した動作。guestの条件分岐はソース/既存specで確認し、今回再起動しない |
| [AssignmentsController](../../app/controllers/assignments_controller.rb)は`current_teacher.assignments`、[SubmissionsController](../../app/controllers/submissions_controller.rb)は所有課題→reviewable_submissions、[Assignment](../../app/models/assignment.rb)は配信クラス/学校をActiveRecordで絞り込む。[Admin::StudentsController](../../app/controllers/admin/students_controller.rb)はjoinsと自校scope、preloadと40件ページング | 監査範囲に新たな認可欠陥は確認せず。全経路の独立侵入試験ではない |
| [StudentAccountChange](../../app/services/admin/student_account_change.rb)等のSQLは固定文のNOWAITロック。クエリの値はActiveRecord条件として扱い、直接SQLはロック/整合性保護に使用 | 標準化目的で削らない。学校/配信/答案の競合制御を壊すリファクタリングは対象外 |
| 配信/表示/入力検証を含むAssignmentsController、採点修正を扱うSubmission、demo verifier等は責務量が多い。認証/CRUD/採点はサービスにも分離済み | 任意改善・低優先。責務整理は別の小さい提案と回帰試験が必要。本PRでは変更なし |
| [PasswordPolicy](../../app/services/password_policy.rb)と登録サービス/タスク、[CredentialSession](../../app/services/credential_session.rb)と認証controllerを照合。READMEに「最低文字数なし」「再設定後も既存セッション継続」という現行説明の誤り | 中：利用案内の誤り。本PRで現在の条件とdigest変更時の失効に訂正。新規モデル直接作成のpolicy検証は登録サービス/タスク側、既存モデルのdigest変更はモデル側で行う。[#50責務表](issue50_validation_responsibilities.md)も参照。console/SQLを正規登録の代替として案内しない |
| [parameter filter](../../config/initializers/filter_parameter_logging.rb)はpassword/token/答案/下書き/所属識別情報等を除外。Jobは主にID・例外クラスだけを記録。[正答生成の診断](../../app/services/question_generator.rb)は応答本文を含めずmetadataのみ | 今回読んだログ出力に明白な秘密値/答案本文出力を確認せず。ただし現実の運用ログを読んだという意味ではない |
| [PDF削除](../../app/services/assignment_deletion.rb)の復旧ログはBlob識別情報/ストレージキー、[外部cleanup](../../app/jobs/ai_file_cleanup_job.rb)は外部File IDを保持 | 運用上の機微情報。閲覧権限・保存期間を管理する。本文や秘密値を公開せず、個別復旧手順とPR118の保持上の限界を[運用詳細](operations_details.md)へ保存 |
| `.gitignore`は環境ファイル・復号鍵・ログ・storageを除外。追跡中の平文private key/AWS access key/GitHub token/OpenAI keyの高確度パターン候補は0。追跡ファイル名にmaster key/秘密鍵/実行ログなし | 限定的な現在treeの検査。暗号化credentialsの復号、実運用ログ、全Git履歴、実DBやファイルの内容は調べていない。漏えい不在の完全保証ではない |
| #117→merge cd97d361→main CI39756657910、#118→66967e9→同main CIを追跡。#39は新main aa52ab5へ統合。PR本文・merge commit・workflowでつながる | 追跡可能。全過去PRのレビュー品質を保証せず、本PRもdraftのまま親レビューへ渡す |

この範囲でアプリの修正を要する新たな深刻な欠陥は確認していません。公開環境のURL/HTTPS/データ保全/監視は未検証として#51/#99へ残します。重大な実装欠陥を別途発見した場合は、この文書PRに混ぜず対象を限定した別作業にします。

## 検証と対象外

- Ruby 4.0.6で`bundle check`成功。`bin/rails routes`成功。`RAILS_ENV=test`と未使用の専用loopback DB URLを指定し、初回監査ではDB接続・schema読込・seedは行っていません。後述の手順訂正検証だけ新規専用クラスタを使用しました。
- RuboCop: 255 files、指摘0。初回はホーム外cache書込みで停止し、`RUBOCOP_CACHE_ROOT=tmp/rubocop`で専用clone内へ変更して成功。
- Brakeman 8.1.0: Errors 0 / Security Warnings 0。
- 既存main CI39756657910の全4job成功をAPIで確認。RSpec 1,839/0は#117のmain検証記録。最終PR headのRSpec/System・lint・Brakeman/bundler-audit・importmap auditはPR Checksで別途確認する。文書のみなのでローカル全RSpecは実行しない。
- 変更文書の相対リンク/画像実在・画像形式/寸法の読取・差分の空白・秘密値高確度パターンを検査。画像は既存#95の実Chrome/合成fixture証跡を再利用し、画像目的の新たなDB・ブラウザサーバーは作らない。
- 本番/AI/AWS/公開ポート/元`~/workspace/quickflow`/既存DB/他タスクのチェックアウトは変更・利用していない。原作業の14項目の未コミット変更にも触れていない。

## Issue #100の残り

目的・ロール/機能・ログイン/ゲスト制限・技術・セットアップ/テスト・CI・安全手順・既存画面をREADMEで参照可能にしました。Phase当時の未確認事項は[履歴](readme_history.md)として保存しています。

未達/保留は、提出対象の本番URL・現在の健康確認・実本番主要フロー、バックアップ/復元運用の実証、外部設計資料/ER/画面遷移の最終schema同期（#101/#102）です。外部URLはリンク先への到達性と、閲覧権限/図の内容の正しさを分けて扱います。外部ワークブック/Whimsicalの編集・DPro提出・Issue closure・mergeは行いません。

外部リンク到達確認: Google SheetsはHTTP 200（認証後の各tab内容は未確認）、WhimsicalはHTTP 403で表示確認未達。ローカル画像3点はsipsで形式/寸法を読取、利用画面JPEGは実画像を目視確認。設計図が現行schemaと一致する保証は#101/#102へ残します。

## 親の独立レビューによる手順訂正

READMEの`quickflow_local_test`では、`student_handwritten_submission_concurrency_spec`・`thirty_student_submissions_spec`・`student_pdf_upload_safety_spec`の既存安全ガードを満たせませんでした。DB名を`quickflow_test`に揃え、毎回新しい専用PostgreSQL 18クラスタ・127.0.0.1の専用ポート・専用ソケットを作る手順へ訂正しました。`PRIMARY_DATABASE_URL`も同じ接続先に固定し、Rails設定と実SQLのDB/host/port/data_directoryをschema準備前に照合、失敗時に続行しないsubshellと専用クラスタだけを停止するtrapを記載しています。ガードやアプリの変更はありません。

記載ブロックから全件RSpecを上記3 specに限定した検証を実行しました。新規`/tmp/qf-test.qlnsUr/data`（実パス`/private/tmp/qf-test.qlnsUr/data`）、127.0.0.1:57519、`quickflow_test`の実接続をschema準備前に確認し、**12 examples / 0 failures**。終了時にそのクラスタだけを停止しました。初回はOS locale不正、次はmacOSの/tmp正規化差でschema準備前に停止し、locale/encoding明示と実パス比較に修正して新しいクラスタで成功しています。既存クラスタ・データの再利用やreset/drop/seedはありません。clone内Storageを使用しました。

管理者ログイン説明の「admin_idだけ」も、実controllerに合わせて`admin_id`と`credential_proof`の設定へ訂正しました。画像・相対リンクは独立レビューでも確認済みで、再撮影はしていません。

最終レビュー前にmain `5c1a4ad8599fced886465494032cf313bfec56b5`を通常mergeしました（#119の教師PDF保存失敗境界と回帰spec）。その差分を確認し、運用詳細の初回教材アップロードとロックの順序を現在の「先行Blob保存→配信確定」に訂正しました。#47/#48全体の完了は宣言しません。全件RSpec/Systemはこの統合後の最終head CIで確認します。
