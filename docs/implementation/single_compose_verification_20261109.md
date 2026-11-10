# 通常版の単一Compose検証（2026-11-09・PR準備段階）

## 対象と安全境界

編集元はMacのVS Codeで開いた独立checkout `~/workspace/quickflow-single-compose-20261109`、branch `chore/single-compose-workflow`。基準mainは `fe607634ef75f1f7d6a4fd1b130f3720ddc86cb4`。アプリ、Gemfile/lock、RSpec本体は変更していない。普段のquickflowは同じmain・clean状態・既存stash1件を保持し、既存storageの内容hashも作業前後で一致。

通常3役（Caddy、Thrust/Puma/Rails＋Solid Queue、PostgreSQL）を共通Composeと既存本番Dockerfileで起動。DockerfileはRuby baseのdigest固定とdevelopment/test依存除外を行った。通常アプリへfake AIを注入せず、本番master key/API key/実生徒データを持ち込んでいない。

ユーザーの後続指示によりguestのローカル作成は延期。作成途中のhelper・設定・新規準備ファイルは非公開の作業領域へ保管した。guest DB/containerは未作成、AWSguestは未変更。負荷計測用の既存Docker一式は今回削除していない。

## 確認済み

- 既存本番DockerfileをMacでbuild成功。共通runtime imageは `sha256:9e760bffd675dce9264a626d9cf7fd6ada8c2a99743d0ecc8d945715d1ab1c7b`。作業中ソースの候補であり、最終PR commitの配備済みimageではない。
- image内Ruby4.0.6、Gemfile.lock SHA-256 `cc157879453690700dfc84722a5f1068af7fc1cb4289aa88982c0009045fab1c`。RSpec/Capybara/Selenium、master.key、ローカル状態・fake AI initializer・起動helperを含まないことを検査。
- production、Active Job=solid_queue、Dispatcher/Worker/Supervisor(fork)/Scheduler各1を実測。
- 新規専用volumeだけを作成し、通常4DBを空DB確認後に明示準備。起動・再起動にはdb:prepareを含めない。
- 実HTTP `/up` は200。ただしHTTP `/login` はSet-Cookieなし、ログインPOSTはCSRF422だった。HTTP health成功をログイン成功と誤認せず、Secure sessionを変更しないままMac標準をHTTPSへ修正。
- 同じComposeでCaddy内蔵CAを使うHTTPSが成功。公開CAだけを指定したcurlで証明書検証し、HTTPS `/login` ではSet-Cookie発行を確認。OS信頼ストアや通常Chromeは変更していない。
- 標準Compose stop/up後、架空学校・教師・生徒・クラス各2件、課題2件、提出2件、Active Storage blob2件、架空採点結果1件が一致。PDFを含む保存全体4ファイルのSHA-256集合hash `9e49d90fb39542fe4bcd89c5719b887b9009ae6868e9c42f312886cb1c3f6fcc` も一致。初期のmarker試験とは別に、実ブラウザ後のPDF/DBで再確認した。
- Ruby依存監査とJavaScript依存監査はいずれも成功、検出された脆弱性なし。
- 旧モード用Ruby削除後の最終RuboCopは301ファイル・違反0。Brakemanはエラー0・警告0。

## MacネイティブRSpec

専用の新規PostgreSQL18.6クラスタ（127.0.0.1:57543、quickflow_test）と当該checkoutのtmp/storageだけで実行した。既存Mac DB/保存先は使わず、クラスタは試験後に正常停止し保持。

- 非system: 2,125例、失敗0（6分3秒）。
- 全suite: 2,263例、1失敗（20分26秒）。
- 失敗: 既存guest PDFの戻る・再描画system例。失敗画面にはPDFと完了文言があり、原因は未確定。
- コード・設定を変更しない再試験: 該当1例成功、guest_browsing_spec全8例成功。
- 初回全suiteの失敗は履歴として残す。再試験成功だけで全suite全成功とは記載しない。

Chrome157に対応する公式driverを標準Selenium経路で利用し、sandbox等を弱めていない。

## 実ブラウザ・整理の結果と残る承認境界

- 通常版HTTPS Chromeは11項目すべて成功。ログイン、PDF配布/表示、ポインタ手書き、下書き保存/復元、提出取消/正式提出を確認。実Solid QueueはAPI key未設定の失敗を正しく保存。教師修正/Excelは別の明示的な架空採点fixtureで確認し、実AI成功とはしない。ユーザー承認済みの新規専用Chrome公開鍵例外のみ使用し、VERIFY_PEER・SAN・期限・実CA/コンテナ/公開鍵を事前照合。OS/通常Chrome/sandboxは不変。
- 共通機能の継承後、旧Compose2枚、Dockerfile.dev/test、bin/local、旧docker/local9ファイルを撤去。既存CIのscan_ruby/scan_js/lint/testはbyte完全一致で保持。Docker検証だけ共通3役のimage識別・HTTPS・worker・stop/upと保存保持へ移行。過去のfake AI HTTPS全フローと同一の検証とは主張しない。
- 旧負荷試験Dockerは残存。すべての試験用Dockerを廃止したとは扱わない。
- 最終commitのPR/CI・差分レビューはこの記録時点で未完了。結果はPRの最終headと対応させて報告する。
- mainへのマージ、普段のquickflowへの同期、AWSの起動停止・設定変更・配備は未実施・別承認。
- AWSの共有Caddyはguest経路を持つ。今回の通常専用Caddyfileで無条件に置換しない。backup隔離復元・queue静止・既存保存先・切戻しを含む移行計画は別ゲート。

実AIの送信・採点精度・課金、実生徒データ、EBS性能、負荷・障害復旧は検証していない。過去のdev/check/test成功を新Compose成功へ転用していない。

## 2026-11-10: 共有入口と同一image移送の追加検証

- Mac独立checkoutだけで、通常3役・Compose1枚のまま共有入口の候補を実装。appとguest_routeはexternal名を参照し、Macの追加接続先は空のinternal network。Caddyだけが両方へ接続し、web/dbはappだけ。guestアプリ・DBは作成しない。
- 共通Caddyfileは通常HTTPS、引数付きimportの追加設定は既存AWSの通常HTTP301とguest route。AWS原本hash `d44eb206e1eae8cf5fd4d4e594ed33a505a6f548979acbe9c25109dbb12695c4` を照合し、Caddy2.11.7のadapt JSONが完全一致。
- 独立HTTPS mockの16項目が成功。301のpath/query保持、転送header7種の400拒否と上流への削除、64,000bytes受理・64,001bytesの413拒否、正しいCA/SNIの200、不正CA/SNIの502を確認。本番hostへ通信せず、公開ACMEや実guestの受入とは区別。
- 必須4引数の欠落はvalidateで拒否。CA欠落や空importはadaptだけでは見逃し得るため、固定import path、ファイルhash、validate、期待host/upstream等のJSON照合を組み合わせる。CIへ入れる同じ検査コマンドをMacでも実行し成功。
- 正規3コンテナ名でnetwork境界を照合。検証用mockはUUIDで識別し、停止・内容保全を確認して今回作成分だけ整理。既存container・DB・PDF・volume・backupは削除していない。
- 通常HTTPSは準備完了後にHTTP/2のhealth/loginを確認。起動初期のエラーを成功扱いせず、webのhealthcheckと検証側のbounded waitを使用する。共有Caddyはwebの起動成功へ依存させず、guest入口を通常版障害へ連動させない。
- 配布方式のリハーサルは既検証image `sha256:85fc47086ad3448877678018f99556b08e7a04c2814599fbc44f524fbf90b921`（実装commit `e1e9d45`、amd64）で行った。save/load前後のimage IDとCPUが一致。archive 218,586,624 bytes、SHA-256 `879525cbf5395105625ae517952f06cc1eeaaa755548eee98d4ca7018effc6b6`。これはMac内の試験であり、最終mainの配布imageでもAWS移送済み成果物でもない。
- この追加候補を含む最終PR CIとexact-head imageの通常ブラウザQAは、結果をPRへ対応づけて報告する。AWSの設定適用・停止・backup・復元・移送・配備は未実施。具体的な判断欄は [backup・切替計画](aws_backup_cutover_plan.md) に残す。
