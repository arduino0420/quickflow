# Issue #79 認証基盤 第1段階

作業元: origin/main ec1ddcca206c02d424f04e3fd78020b2a48d7f46。
作業場所: /private/tmp/quickflow-issue79-auth / fix/issue-79-authentication。
実装承認: 認証カウンタ、ログイン/管理者再認証制限、旧セッション無効化、401と答案保持の検証。
第2段階の復帰処理・パスワード文字数ルール・AI送信管理・AWS・PDFアップロード変更は含めない。

## 動作

| 用途 | アカウントと接続元 | アカウント全体 |
| --- | --- | --- |
| 全ロールのログイン | 10回/10分 | 50回/15分 |
| 管理者再認証 | 5回/5分 | 10回/15分 |

パスワード照合前に両方の枠をDBトランザクションと行ロックで確保する。同時要求も上限を共有し、bcrypt計算中はカウンタのロックを保持しない。成功は同じウィンドウの本人カウンタを消去する。遅れた成功が次のウィンドウを消さないよう期限も照合する。
上限到達後は429とRetry-Afterを返し、制限中の要求で期限を延長しない。ログアウトは制限しない。存在しないアカウントにも同じ制限・応答を使い、bcryptのダミー照合で早期終了による時間差を減らす。完全な時間差不存在を保証するものではない。

IPだけで全員を止めるカウンタはない。接続元はREMOTE_ADDRを用い、利用者が送ったForwardedヘッダーでは分割しない。プロキシ越しに同じ値になっても、別アカウントは別枠となる。管理者再認証は変更対象の生徒IDでは分割せず、ログイン用カウンタとは独立する。有効な既存の15分証明は維持し、毎回パスワードを必要とする操作の条件は変えない。

新規表authentication_attempt_bucketsにはHMACキー・回数・期限のみを保存する。生の識別情報・IP・パスワードは記録しない。キャッシュ追い出しやプロセス再起動でリセットされない。カウンタの読書きでDB障害が発生した場合は新しい認証を503で拒否し、制限なしで通さない。認証済みの通常の筆記・保存・閲覧はカウンタ表へアクセスしない。期限切れ行だけを最大1000行/回で整理するJobを毎時実行する。

## 旧セッションと答案

ログインで検証したモデル種別・ID・password_digestに結び付くHMACを暗号化セッションへ保持する。各要求の認証時に現在値と照合する。updated_atは使わないため、通常の所属等の編集は認証世代を変更しない。パスワード変更・同じパスワードへの再設定は新しいダイジェストとなり、別端末を含む旧セッションを無効化する。管理者の基本認証が無効なら再認証証明も利用できない。
一度認証した結果は要求内で固定し、その後のパスワード変更で進行中の保存・提出を取り消さない。次の要求は旧認証を拒否する。401判定のために旧Cookieを新しい世代へ自動昇格しない。

下書きAPIの既存401を維持し、手書き提出APIも401を返してログイン画面へリダイレクトしない。JavaScript、筆跡座標、ペン、消しゴム、PDF生成、採点処理は未変更。ブラウザテストでは実際のパスワード変更と実際の401を使い、未保存筆跡、保存済み下書き、生成済みPDF、提出識別子の保持を確認する。

第1段階での401後は、現行画面が筆跡を保持したまま保存・提出を停止する。同一画面から安全に再ログイン・CSRF更新・競合照合して再開する処理は第2段階の承認待ち。画面を閉じたりブラウザが終了した場合の未保存データの消失は防げない。第1段階だけを本番反映可能とは判断しない。

## 既存機能・移行

- 生徒の数字のみのパスワードや、既存の登録/再設定条件は変更していない。新たな文字数検証は導入していない。
- 既存Cookieには世代証明がないため、一度再ログインが必要。授業外の移行を前提とし、今回デプロイは行っていない。
- 対象を狙った一時的なロック妨害はアカウント単位の制限でも残る。解除期限の延長を防ぎ、他の生徒へ波及させない。攻撃が続けば復帰後に再制限され得る。
- 以前の管理者テスト3件は旧セッション維持を期待していたため、承認された失効仕様に沿って変更した。他の29人のアカウント不変、未認証の更新拒否、新認証後の再認証要求を確認し、期待値を緩める変更にはしていない。未認証の手書き提出APIをリダイレクトではなく401にする仕様も、既存の2例で401とLocationなしを検証するよう変更した。
- 本番へ適用する場合のmigration・全Webプロセス更新・再ログイン案内は別途承認が必要。今回は専用の空DBにだけmigrationを実施した。

## 検証環境

PostgreSQL 18.6の専用クラスタを/tmpに作り、外部TCPを無効化し、所有者だけが利用できるUnixソケットを使用。通常の5432番DBは未使用。Chrome 155.0.8059.85の別WebDriverセッションで検証。最終比較は専用クラスタのautovacuumだけを停止した同一条件で実施した。本番設定やリポジトリの環境設定は変更していない。
既存の並行提出テストにはDB名quickflow_testの安全ガードがある。最初に別名DBで得た12失敗はこのガードによるものだったため、ガードは緩めず、専用クラスタ内のDB名を合わせて未変更mainの基準を取り直した。基準と実装は別DBで、接続がないことを確認して名前だけを切り替える。
以前の共有DBでの9失敗（ロック8件・Chrome1件）は、今回の変更による失敗と分けて扱う。

## 検証結果

| 検証 | 結果 |
| --- | --- |
| 未変更main・通常の保守有効 | 1,592例、失敗0 |
| 未変更main・最終比較用の保守停止条件 | 1,592例、失敗0、6分15秒 |
| 最終実装・同じ保守停止条件 | **1,626例、失敗0、6分17秒** |
| 最終関連テスト（認証、管理者編集、提出、文字数規則維持） | 107例、失敗0 |
| 30人の並行ログインと保護画面到達＋CSRF有効の答案保持 | 4例、失敗0 |
| RuboCop | 210ファイル、指摘0 |
| Brakeman | 79 checks、Errors 0、Security Warnings 0 |
| bundler-audit --update | 既知の脆弱性の該当なし |
| importmap audit | 成功、ただし既存設定では監査対象0件 |
| PDF.js 6.4.299 / pdf-lib 1.17.1のnpm bulk監査 | HTTP 200、該当アドバイザリなし |
| git diff --check | 成功 |

Gem監査DB: ruby-advisory-db 5fd86bbd406995ea4ed2df84651b209e28072031。Gem/JS依存バージョンは変更していない。importmap自動監査の不足そのものは今回の認証基盤の範囲外であり、手動の明示的なパッケージ照会で補った。

### 失敗の切り分け

- 以前の共有DBでの9失敗を、修正版の成功に置き換えて隠してはいない。元のログと今回のログは別に保持した。
- 別名の専用DBを使った最初の12失敗は、既存のDB名ガードによるもの。ガードを変更せず、専用クラスタ内のDB名をquickflow_testに合わせた。
- 中間版の全件実行は1,624例中7失敗。3例は旧セッション維持/答案APIのリダイレクトを期待していた既存仕様との差異。承認された失効/401仕様に沿って検証を更新した。残る4例は既存LegacyBackfillテストとautovacuumの競合で、診断でteachersのShareUpdateExclusiveLockとautovacuum workerを確認した。
- 既存のNOWAIT条件や、別接続から意図的に書き込みロックを保持するテストは変更していない。静止条件を必要とする移行テストについて、専用クラスタのバックグラウンド保守だけを止め、未変更mainと最終実装の全件成功を確認した。
- 過去のChrome要素参照エラーは最終比較で再現していない。今回のアプリ修正でChromeの不安定性を修正したとは判断しない。
- 最終実行に自動リトライやテスト除外は使っていない。最後のコードで全件を通した。

### 追加テストの内容と限界

- 3ロールの正常ログイン/ログアウト、失敗上限、固定期限と期限復帰、未知アカウントとの同じ応答、偽装Forwardedヘッダー、学生番号の別表記を確認。
- 同じ接続元として30件のRails要求を同時に開始し、30人それぞれが独立したCookieでログイン後の保護画面へ200で到達することを確認。1人をロックしても他29人は到達する。
- 12個のOSプロセスで同時比較を行い、単一接続元では10枠、多接続元では全体50枠を超えないことを確認。Railsアプリを別プロセスで終了・新起動した後も、制限と解除時刻を維持することを確認。実機30台やAWS上の負荷性能保証ではない。
- 既存の認証済み授業セッションは、ログインへの攻撃による制限中でも利用できる。ログアウトで試行制限を消せない。
- 2ブラウザの旧認証拒否、同じパスワードへの再設定による失効、通常のtouchで失効しないこと、世代証明のない既存Cookieを自動昇格しないことを確認。
- 管理者再認証の対象切替による回避拒否、固定15分証明、パスワード変更による旧認証/再認証証明の失効、カウンタ障害時の拒否と対象不変を確認。
- 認証前に失効した保存/提出は401とLocationなしで拒否。認証済みの要求にパスワード変更を挟んだテストでは保存/提出を完了し、次要求を拒否する。提出PDF・下書き・ジョブの重複や上書きを防ぐ。
- CSRFを有効にしたChromeで、実際のパスワード変更後の自動保存401と提出401を確認。保存済み下書き、未保存の2画目、dirty状態、生成済みPDF全バイト、提出UUIDを保持する。
- 既存の別生徒コンテキスト拒否と重複提出拒否も全RSpecに含む。復帰処理は未実装。

### 再現コマンドとログ

最終全RSpecは次の接続先で実行した（通常の5432番サーバーではない）。

```sh
RAILS_ENV=test DATABASE_URL='postgresql:///quickflow_test?host=/private/tmp/quickflow-issue79-pg-socket&port=55479' /usr/local/bin/rbenv exec bundle exec rspec
```

- 基準のログ: /private/tmp/quickflow-issue79-baseline-controlled.log
- 最終全件のログ: /private/tmp/quickflow-issue79-auth-final-rspec.log
- 中間診断のログ: /private/tmp/quickflow-issue79-auth-all-rspec.log
- ブラウザ/共有IPのログ: /private/tmp/quickflow-issue79-auth-final-browser.log
- 専用クラスタのデータ: /private/tmp/quickflow-issue79-pg
- 専用PostgreSQLのログ: /private/tmp/quickflow-issue79-postgres.log

検証終了後、今回起動した専用PostgreSQLは停止する。データ・ログは保持し、既存PostgreSQLは停止しない。

## 完了状態

元の未コミット18ファイルとIssue #78の回帰テストは、開始時のSHA-256とGit状態に一致することを確認。元の退避アーカイブも保持。HEADはec1ddccのままで、変更は未コミット。commit/push/PR/merge、本番DB/AWS接続は実施していない。
第1段階は実装・ローカル検証まで完了。第2段階の承認前に本番反映可能とは判断せず、復帰機能・パスワード移行の実装にも進まない。


## 変更ファイル一覧

- `app/controllers/admin/base_controller.rb`
- `app/controllers/admin/sessions_controller.rb`
- `app/controllers/application_controller.rb`
- `app/controllers/sessions_controller.rb`
- `app/controllers/student/submissions_controller.rb`
- `app/controllers/student_sessions_controller.rb`
- `app/jobs/authentication_attempt_cleanup_job.rb`
- `app/models/authentication_attempt_bucket.rb`
- `app/services/authentication_throttle.rb`
- `app/services/credential_session.rb`
- `config/recurring.yml`
- `db/migrate/20261021000000_create_authentication_attempt_buckets.rb`
- `db/schema.rb`
- `docs/implementation/issue79_authentication_stage1.md`
- `spec/requests/admin_account_management_spec.rb`
- `spec/requests/admin_teacher_editing_spec.rb`
- `spec/requests/authentication_security_spec.rb`
- `spec/requests/shared_ip_authentication_spec.rb`
- `spec/requests/student_submissions_spec.rb`
- `spec/services/authentication_concurrency_spec.rb`
- `spec/services/authentication_throttle_spec.rb`
- `spec/services/credential_session_spec.rb`
- `spec/system/student_pdf_preview_spec.rb`
