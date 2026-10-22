# Issue #93: ローカルで検証する閲覧専用ゲスト

本実装はローカルのコード・隔離DBでの検証範囲です。公開デモ運用の完成ではありません。
#93 はopenを維持します。`RAILS_ENV=test`のサーバーをインターネット公開してはいけません。
AWS操作、本番変更、新規課金、実AI通信、実学校・生徒データは対象外です。

## 最小構成

`QUICKFLOW_GUEST_LOGIN=true`かつRails testのときだけPOST `/guest/:role`とホームの入口を追加します。
通常OFF、本番・開発では入口ルート自体がありません。設定を誤って有効にしても実AI/Jobは停止します。
既存ログイン・CredentialSession/digest照合・CSRF・学校/所有者scope・admin再認証を維持します。
DB/schema/依存追加はありません。通常ログインの権限やAI仕様は変更しません。

開始前と各閲覧前に、#92 `Demo::Seed`の実DB endpoint・専用DBコメント・専用Disk/root・隔離印・
未知schema/table・symlink拒否と、全業務行/全storageファイルのmanifestを照合します。
`verify_guest!` はseed・修復・パスワード変更・ロックファイル作成を行いません。
既存manifestとseedロックファイルが必須です。不完全・未seed・改変された環境は拒否します。

サーバー側allowlistからDEMO1校の管理者/教師/提出済み生徒を選びます。クライアントからIDや学校を受けません。
検証済みseedのdigestを使って通常のCredentialSessionを発行します。ロール切替はreset_sessionします。
15分の乱数nonceを、既存authentication_attempt_bucketsのHMAC keyに保持します。
切替・ログアウト時にこの行を失効させ、旧cookieの再送を拒否します。期限は閲覧で延長しません。
これは認証内部状態であり、業務行/PDFのmanifest不変とは区別します。
既存AuthenticationThrottleに独立したguest用identityで開始回数を記録し、成功でも消しません。
同一peerは10回/10分、全peer合計50回/15分までです。共有IPでの制限を許容する小規模ローカル仕様です。
認証内部表の追加はseed再実行の完全一致条件から外しません。ゲスト利用後のseed rerunは止まるので、
使用中のデモをseedでreset/修復しないでください。

## 許可する閲覧

- 管理者: 自校トップ、教師一覧、生徒一覧（既存school scope）。
- 教師: 自分の配信済み課題一覧/詳細/成績Excel、答案詳細/認証付き答案PDF（既存teacher/配信scope）。
- 生徒: 自クラスの課題一覧/詳細/結果、認証付き教材/自分の答案PDF（既存school/classroom/owner scope）。

表示には「架空データの閲覧専用ゲスト」「実際のAI実行結果ではありません」を明示します。
管理・編集・配信・削除・採点保存・再開ボタンは隠します。提出済み生徒だけを選ぶので解答入力は不要です。
ゲスト終了と3役の切替を表示します。PDFをActiveStorageの公開URLへ渡しません。
ActiveStorage標準route無効化は変更しません。

## 状態変更経路の棚卸しと拒否

ApplicationControllerでrole別controller/actionのGET allowlist以外は403にします。
ログイン開始/切替と既存3種のDELETE logoutだけを例外とします。CSRFは通常どおり先に検証します。

|経路|操作/副作用|ゲスト|
|---|---|---|
|POST /assignments|PDF upload、課題/配信保存、QuestionGenerationJob|拒否|
|PATCH/PUT/DELETE /assignments/:id|名前更新、課題/採点/添付削除とcleanup|拒否|
|POST /students|教師による生徒登録|拒否|
|POST/PATCH/PUT /admin/teachers|教師登録、担当/ID/password変更、再認証|拒否|
|POST/PATCH/PUT/DELETE /admin/students|生徒登録、更新、削除、再認証|拒否|
|POST /admin/students/:id/confirm_update|編集確認と再認証状態|拒否|
|PATCH/PUT /admin/students/:id/password_reset|password変更|拒否|
|PATCH/PUT /assignments/:assignment_id/submissions/:id|先生判定/得点更新|拒否|
|POST .../submissions/:id/resume_grading|世代更新/AI再実行Job|拒否|
|PUT/PATCH /student/assignments/:id/answer_draft|下書き保存/追記|拒否|
|POST /student/assignments/:id/submission|PDF upload、答案提出、AnswerReadingJob|拒否|
|POST /login, /student/login, /admin/login|通常認証への移行|ゲスト終了後に通常ログイン|
|GET new/edit/confirm_destroy/password_reset/edit|編集token/再認証準備や編集導線|拒否|
|GET pdf_preview, answer_draft, answer_draft/recovery, submission|入力・復旧token準備等の補助経路|拒否|
|ActiveStorage direct upload/標準blob route|公開upload/署名URL|既存どおりrouteなし|
|未定義の管理者CRUD/新しい経路|未承認操作|allowlist外は拒否|

許可GET内は検索・集計・send_dataのみ。Student showの未保存buildはDBへ保存しません。
Excelはメモリで生成し、業務行やstorageを書きません。認証試行・session失効行以外は書込み不要です。
`AiClient.build`はゲスト設定時、秘密設定を読む前に例外を投げます。
ApplicationJobもperform前に停止するので、デモ内の誤登録Jobから外部AIへ進みません。

## ローカル検証と公開前条件

#92の新規ローカルクラスタ作成手順と完全一致seedを先に検証する必要があります。
本変更はそのローカル環境に対するテストであり、公開手順は提供しません。
通常test DBでのRSpecは新規空クラスタで実行し、seed済みデモDBを再利用しません。
接続ではPRIMARY_DATABASE_URLも新規DATABASE_URLへ固定し、Rails自身のhost/port/data_directoryをmigrate前に照合します。

公開前には、production相当の独立デモ環境・最小DB権限・専用非公開storage・TLS/cookie/CSRF/proxy設定・
実運用の負荷/濫用制限・秘密分離・監視・認証内部状態の運用を設計し、公開を別途承認してから検証します。
現行test専用seedをそのまま公開環境に転用しません。tenant lease/reset workerや管理CRUDは追加しません。

検証結果はPRに記録します。全RSpecやCIの進行中の結果を成功扱いしません。

## seed時刻の修正

実値比較で、ActiveStorageの添付親の遅延touchがseedのmanifest取得後にupdated_atを更新することを確認しました。
JSON.generate(Time)は小数秒を落とすため、同じ秒なら不一致が見えず、秒境界をまたぐ場合だけ拒否されていました。
seed内のattach!直後だけでrecord.touchを実行し遅延更新を確定させます。通常の添付/提出処理は変更しません。
manifestの日時はISO8601の6桁小数秒に統一し、1マイクロ秒の改変も拒否します。
旧形式manifestは安全側で拒否します。既存manifestを再生成して上書きせず、新規専用クラスタ/Storageで検証してください。
閲覧リクエストはmanifest照合と既存scope検索を同じrepeatable-read transaction内で実行します。
途中で別接続から行が追加されても、検証後の検索だけへ現れることを防ぎます。

## 検証記録（2026-10-22）

- mainの#109 merge SHA `6cc75b2909eb51679df8a230baf72c5a485b912f`から専用clone/branchを作成。
- RSpec用: 新規 `tmp/guest-pg.8LCcDak1`、127.0.0.1:54888/quickflow_test。
  実Rails接続のDB名・host・port・data_directoryを照合後migrate。
- 接続中断前の追加クラスタは`tmp/guest-pg.hKf8qqhV`、54941と確認。空DBへのmigrateまで完了していたため
  重複作成せず再利用し、修正前の実seedを2回実行。修正前manifest/データは保持。
- マイクロ秒精度へ変更後の実デモ用は新規 `tmp/guest-final-pg.WeAJPjJG`、49379。
  endpoint/data_directoryをRailsで照合後migrateし、修正版の実seedを2回実行。
- 関連RSpec40件・失敗0件。3役閲覧、日本語リンク/切替/終了System Spec、3役各mutation全route拒否、
  学校/所有権、旧cookie再送拒否、期限、CSRF、OFF/本番相当/manifest消失/改変digest/PDF拒否、AI/Job停止を含む。
- RuboCop232ファイル・指摘0件、Brakeman警告0件。
- 実49379デモでstubなしのmanifest検証、CSRF明示ONのHTTP統合確認に成功。
  3役閲覧、既存認証付き答案PDF、下書き書込み403、logout303、全業務行/ファイルdigest不変。
  実API生成禁止・enqueue通知例外の監視下でJob/APIなし。
- 全RSpecと最終head CIの結果はPRで追記。ここまでの成功とは区別する。
