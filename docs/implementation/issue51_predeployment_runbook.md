# #51 / #99 運用監査・配備実績と最小運用案

更新日: 2026-10-23 UTC。最終稼働基準: [mainacd22fb9](https://github.com/arduino0420/quickflow/commit/acd22fb9e9f7241c3e434a147edc09f5f3a13ef7)。初回コード監査9704b30・公開観測2026-10-22は履歴として保持する。
[Issue 51](https://github.com/arduino0420/quickflow/issues/51)、[99](https://github.com/arduino0420/quickflow/issues/99)、[提出チェック](issue103_submission_evidence.md)を参照。
今回のPRは文書のみ。以下の運用実績は別途明示承認を受けた作業の記録で、この文書変更が再配備・本番操作を実行するものではない。元checkoutの14未コミット項目を保護し、task専用cloneで編集した。

## 最新状態（2026-10-23、配備後の確認済み記録）

以下は実行担当の観測と所有者報告を分けた記録。初回監査/手順案の「未実行」は当時の履歴であり、この節を現在状態として参照する。

- **最新の通常/ゲスト稼働版:** source `acd22fb9e9f7241c3e434a147edc09f5f3a13ef7`、app image `sha256:d2d31173a09eaa318677d110684e56185b03d746a94ec4abf4b133506ab24f2e`。[main CI40027128404](https://github.com/arduino0420/quickflow/actions/runs/40027128404)全4ジョブ成功、2,049例/失敗0。1adb1530からのruntime差分は明示的pen/palm入力処理とcrass1.0.7→1.0.8のみ。DB/schema/設定/保存形式/採点jobは変更なし。PR23は含まない。今回の文書commitは稼働imageに含まれない。
- **最新の通常web切替:** 2026-10-23 22:02:59–22:04:12 UTC、約73.1秒。maintenance→queue/claim/transaction静止を連続3回確認→旧worker正常停止→新版web/worker→公開再開。migration20本/最新20261022110000、storage mount継続。公開再開前に生徒・提出・採点結果・blob・attachmentの集計一致を確認。全レコード/添付checksumの再照合、新規backup、migration/seed/DB復元を行ったとは記載しない。
- **最新のguest切替:** 同日22:01:30–22:01:48 UTC、約17.2秒。webだけ更新し、専用DB/鍵/TLS/read-only mountと864MiB/1CPU ceilingを保持。3役HTTP smoke、strict TLS、Origin拒否、read-only・scope、PDF/Excel形式識別、logout成功。現在版の新たなChrome描画確認は行っていない。旧web/imageは停止状態で保持。
- **最新の通常公開確認:** [通常トップ](https://13-231-93-159.sslip.io/)・/up・3loginは200、Cookie Secure/HttpOnly/SameSite=Lax/Path=/。Caddy設定はmaintenance前と完全一致。新hostnameのSupervisor(fork)/Worker/Dispatcher/Scheduler各1の最近heartbeat。ready/claimed/failed/blocked/scheduledとclaimは観測時0。ソースdigestと配布JSでpen修正を確認し、両runtimeでcrass1.0.8を確認。永久のqueue0、AI精度、実機解消の証拠ではない。
- **直前版1adb1530のChrome確認（履歴）:** 大きいロゴ、元の説明2文、教師→生徒→ゲストの同色ボタンと遷移、guest3役・教師/生徒のPDF描画を確認。今回の差分でこれらのview/route/CSSは変更していない。採点待機の丸1.1rem/上下10px・reduced-motionと不要案内除去は既存asset/合成表示の証拠で、実AIの再実行ではない。
- **ペン修正の限界:** [PR134](https://github.com/arduino0420/quickflow/pull/134)の合成pen/palm/finger試験と現在版の入力単体3例成功を再利用。今回、認証付き学校本番で新たに筆記・保存・正式提出はしていない。Lenovo実機のpointerType/根因・解消は未確認。以前の成功した架空筆跡確認と今回の修正配信を区別する。
- **公開guest:** [閲覧専用入口](https://qfd-4c18332acca47671.13-231-93-159.sslip.io/)は別host/専用架空data。通常学校アカウントをguest化していない。real AIは今回呼んでいない。

### 以前の保全・移行と認証付き主要フロー

- **実行担当の配備記録:** source `047ba388c662944f0584159d9fa3437195e57434`、image `sha256:c9910bed75a12d59eb59c6312acd2156c4d5469dbb9d2f040d0435870f0c960f`。Ruby4.0.6/Rails8.1.4/qpdf12.4.2。CI [39886322221](https://github.com/arduino0420/quickflow/actions/runs/39886322221)全4ジョブ成功、2,034例/失敗0。PR23は含まない。このローカル文書差分は稼働imageに含まれない。
- **実行担当の保全/配備記録:** DB4接続とPDFの整合backup、同一サーバーの隔離復元でschema/migration/集計/FK/sequence/添付checksumを照合。復元26blob、隔離artifact約117MB、検証containerは停止。直前の別backupを保持して旧worker全終了後にreview済みadditive migration2本を適用（18→20、最新20261022110000）。既存値/PDFとvolume継続を公開前照合。一時503は03:33:54–03:34:34 UTC、約40秒。seed/reset/legacy replay/claim backfill/down migrationなし。古いDBの上書き復元や旧worker混在は禁止。
- **実行担当の公開確認:** TLS検証成功、HTTP→HTTPS301、root/up/3role login200。Cookie Secure/HttpOnly/Lax/Path=/。HSTS未設定。通常RailsのHost allowlist/force_ssl/assume_sslは未追加、Caddy終端による現在の構成と区別する。worker heartbeat更新、観測時ready/claimed/failed/blocked/scheduled/未完了0。継続監視やAI精度の証明ではない。
- **実行担当の認証付き架空データ確認:** 3role login/logout、学校限定一覧、教師からadminの拒否、教師修正0→5、生徒結果5/正解、実Excel download（数値5/未提出blank）、教材PDF表示、管理者編集preview/cancelで元番号維持。通常Chromeで教師iframe答案PDFを描画し、保存済み筆跡を再読込・「保存済み」待機後に再表示。保存PUT200/操作1件というDB証拠と描画を分けて確認。初回の「保存失敗」は復元完了観測不足のため撤回。IAB黒表示の内部原因は未確定。専用架空dataは保持、session終了。実ユーザー答案/削除/通常配信/正式提出/実AIはこの検証で使っていない。画像・限界は[提出証拠](issue103_submission_evidence.md#本番の追加証拠2026-10-23)参照。
- **所有者報告（担当による再実行・独立観測ではない）:** 通常UXと実AIを使う配信・提出・採点を行い、問題なしとの報告を受領。数学精度全件、全端末/全PDF、provider障害/遅延の保証とは扱わない。

### #51 手動運用方針（所有者合意済み、設定変更なし）

2026-10-23に所有者が承認した範囲は、授業・審査の前後に処理エラーと空き容量を手動確認、重要変更前と週1回を目安にbackup、直近2回と復元確認済み版を保持、自動削除なし、同一サーバー保管の災害限界の認識、有料監視/自動化を当面導入しない、である。以下の詳細閾値やHost/HSTSの選択まで承認済みとはしない。

| 項目 | 現状と提出前の最小判断案 | 将来推奨/追加権限が必要な操作 |
| --- | --- | --- |
| TLS/Cookie/Host | 有効TLSとSecure Cookieの確認結果を採用。HSTSなし、Rails Host allowlist未追加を明示し、#51は監査結果/必要変更の明示がDoDで、未実装HSTS/Host強化の導入そのものを追加完了条件にしない | HSTS/Host変更は局所検証・別review/配備承認後。HSTS自体をDPro原文の追加必須条件にしない |
| Job/容量 | 所有者が授業/審査前後に処理エラーと空き容量を手動確認する方針は合意済み。具体的な読み取り候補は既存手順のheartbeat、failed、ready/claimed滞留、空き容量。failed>0、heartbeat2分超停止、ready/claimedが15分超継続、空き容量10GiB未満を要調査とする技術的な暫定推奨（この数値は所有者未承認）。本文/生徒情報/引数は出力しない | 自動通知は未設定。現時点は所有者が確認/連絡を受ける手動運用案。外部通知先・自動化/有料サービスを導入するなら別承認 |
| Backup/復旧 | 既存の整合backup/復元実証を採用。合意済みの目安は重要変更前と週1回、保持方針は直近2回＋復元確認済み版。自動削除しない。これは取得・保持の方針であり、定期実行の自動化や今回のbackup取得・整理を意味しない | 同一サーバー喪失には備えきれない限界を説明し、所有者がこの当面方針に合意。off-host暗号化copyは推奨だが新しい保存先/権限/費用/実データ移送の承認前に行わない |
| 切戻し/ログ | reviewed drain/reconciliation/migration手順とstate-aware recoveryを採用。新しいaccepted writes後の旧image単独復帰/旧DB上書きは禁止。認証情報、答案、raw job argsは公開ログ/Issueへ出さない | 障害時の判断担当/連絡方法を決める。破壊的復元はその時点のデータ保護・個別承認が必要 |

手動頻度/backup目安/保持/自動削除なし/同一server限界/有料監視・自動化なしは合意済み。詳細閾値とHost/HSTS強化は未導入の技術提案で、承認済み設定や必須の追加導入とは扱わない。自動監視導入済み・定期backup実施済みとは記載しない。実測/rollback証拠と監査判断を整理し、任意upgradeを追加の卒業条件にしない。

### 公開Guest評価導線（同一server・架空データ専用）

[DPro curriculum3027](https://diver.diveintocode.jp/curriculums/3027)の機能要件は「管理者と一般ユーザそれぞれのゲストログイン機能を実装すること」（2026-10-23の認証済み原文確認）。読み取り専用で十分とは明記されておらず、書込/配信/AI実行もguest要件として明記されていない。管理者・教師・生徒の閲覧を最小実装とした工学的判断であり、公式合格の保証ではない。独立した別serverはDProの要件ではない。

- **実構成:** 通常学校hostと別の上記public guest host。既存Caddy→専用gateway→Pumaは両区間TLS/CA/hostname検証、Host維持、転送header除去。専用PGはnamespace loopback限定。worker/AIなし。専用DB/roles/session鍵/storage/manifestで学校DB/PDF/credentialsや実データ復元コピーを使用しない。[Profile](../../lib/demo/profile.rb)/[TransportBoundary](../../lib/demo/transport_boundary.rb)/[demo-web](../../bin/demo-web)のguardを保持した。
- **検証:** fresh cluster identity、DB grantsとmanifestを確認。業務/ActiveStorageはSELECT、auth nonce/throttleだけ限定DML、runtimeのstorage/controlはread-only。3役login/logout・旧cookie失効・他校404・変更系403・正しいCSRF付き異なるOrigin422・偽造転送header400・PDF/Excel形式識別が成功。wrong Hostの空200はapp本文/session非配信の確認に限定し、明示的HTTP拒否とは呼ばない。HTTP確認後manifest一致。
- **network:** 専用internal bridgeにhost IPv4/IPv6アドレスなし、guest default routeなし。承認された専用bridgeだけIPv6を無効化し、元値/限定rollbackをprivate運用記録に保管。限定宛先（host SSH、logical gateway HTTPS、既存Caddy管理API）への接続不可、Caddyから許可guest TLS経路へ到達、専用PGへnamespace外から到達不可を確認。これは全宛先/全port網羅のnetwork scanではない。Caddyの一時peer接続は試験後に元と一致、公開時は意図したpeerだけを接続した。
- **資源:** PG384MiB/0.5CPU＋web384MiB/0.25CPU＋gateway96MiB/0.25CPU、合計864MiB/1CPU ceiling。初期化もこの合計内で逐次実行。通常本番の上限ではない。upstream `max_conns_per_host:2` は接続数であり、同時HTTP要求/HTTP2 streamが2本までという保証ではない。既存throttle/64KiB body制限を維持。heavy build/負荷試験/新server/有料AIなし。通常/guest同居のピーク負荷は未測定で、影響ゼロや無償運用を保証しない。
- **証明書:** public TLSは既存の有効・規約同意済みLet’s Encrypt default accountを再利用し、issuerを限定。新規ACME account/新規規約同意なし。内部CA/keyは独立生成、OS trust/firewallの変更なし。公開hostnameは証明書発行/透明性ログに現れ得る。
- **停止/復旧:** 異常時はguestだけ停止、追加したguest routeと通常トップ導線だけを戻し、通常サービスを維持する。同時変更があれば全設定を旧snapshotへ上書きせず自分の差分だけを扱う。DB/fixtures/鍵/旧image/evidenceは削除せず保持。guestはrestart:noで自動再起動設定を追加していない。host再起動等の後は専用bridgeの無address/IPv6設定・peer・容量・TLSを再確認してから手動開始し、停止中のguest公開入口の可用性を保証しない。全server共通sysctl/firewallへ広げない。

## 初回監査の履歴（以下の未確認は当時の状態）

## 確認済みと未確認を分ける

| 対象 | 証拠・判断 |
| --- | --- |
| 現行source | 上記main。#47永続台帳、PR123/#46 claim、PR122/qpdf、PR127 Secure Cookie、PR125/#49集約、PR128/83を含む。PR23はVips同等性/Mac test portability未完のため、2026-10-23に所有者指示で未merge close。branch/history保持。実稼働版とは未照合 |
| 歴史的owner handoff | URL `https://13-231-93-159.sslip.io`、commit `a35f2ea54ed10953592283edc73b08321701fbbe`、image `quickflow:pr87-a35f2ea`。現在の稼働identityとは未照合 |
| 公開経路 | 以下の6回のbounded GET/HEADのみ。Caddy応答は確認。EC2 instance、image digest、DB接続先、mount、workerは未確認 |
| CI | [main CI39876600200](https://github.com/arduino0420/quickflow/actions/runs/39876600200)は親タスク確認で2,034例/失敗0・4ジョブ成功。提出対象headのChecksは別確認 |
| デモ | [production demo](issue93_production_demo.md)は独立profile。公開URL・実インフラは未確認。学校アプリURLからデモ稼働を推測しない |

### 公開HTTP観測（2026-10-22 11:02:03–04 UTC）

curlの標準CA/hostname検証を有効にし、connect timeout 5秒、全体15秒、redirect追従なし、認証/cookie再送なし。本文は破棄した。

| 要求 | 結果 |
| --- | --- |
| HTTPS GET `/` | HTTP/2 404、curl exit 0、ssl_verify_result 0。原因は未判定 |
| HTTPS GET `/login` | 200、TLS検証成功 |
| HTTPS GET `/student/login` | 200、TLS検証成功 |
| HTTPS GET `/admin/login` | 200、TLS検証成功 |
| HTTPS GET `/up` | 200、TLS検証成功。Rails起動確認だけでDB/AI/queue健全性を保証しない |
| HTTP HEAD `/` | 301、Locationは同じhostのHTTPS `/`、Server: Caddy |

HTTPS応答は `via: 1.1 Caddy`。3ログイン応答は `_quickflow_session` に Path=/、HttpOnly、SameSite=Laxを返したが **Secureなし**、Domainなし。Cookie値は保存・掲載しない。ログイン3画面と/upにはnosniff、SAMEORIGIN、strict-origin-when-cross-origin、X-XSS-Protection:0。今回の全HTTPS応答にHSTSはなかった。教師/生徒はprivate, must-revalidate、管理者はprivate, no-store。証明書issuer/期限/chain詳細は採取しておらず、TLS検証成功と区別する。version識別情報は採取していない。404やCookieの原因を特定したとは扱わない。この結果は新mainの主要機能・実ユーザーフローを検証しない。

[PR127](https://github.com/arduino0420/quickflow/pull/127)の通常production Secure Cookieは上記mainへmerge済み。`_quickflow_session`、HttpOnly、SameSite=Lax、Path=/を保持し、demoのhost cookieを別設定とする。[設定spec](../../spec/configuration/session_cookie_spec.rb)が証拠。force_ssl/HSTS/Host/proxyの変更ではない。上記の古い公開応答と矛盾せず、**配備と公開Cookie再検証は未確認**。

## 現行コード監査

リンクは上記SHAの各相対パスを照合する。実サーバーの有効設定とは別。

| 根拠 | 所見・次に必要な証拠 |
| --- | --- |
| [production.rb](../../config/environments/production.rb) | 通常profileのassume_ssl/force_ssl/Host例はコメント。外部TLS終端、forwarded headers、HTTP ingress、Secure=trueはコード確認済み。終端を含む全体で検証し、追加設定変更案は別承認。公開CookieのSecure欠如は解決/再検証が必要 |
| [deploy.yml](../../config/deploy.yml) | server `192.168.0.1`、proxy SSLは雛形。Kamalが実デプロイ経路とは断定しない。storage volumeは`quickflow_storage:/rails/storage`の宣言のみ |
| [storage.yml](../../config/storage.yml)、[database.yml](../../config/database.yml) | 通常productionはDisk `storage/`、primary/cache/queue/cableのPostgreSQL接続。実URL上書き、別host/volume、容量・永続性・backup保管先は不明。会話中のパスを実mount証拠に置き換えない。DB dumpにはPDFが入らない |
| [puma.rb](../../config/puma.rb)、[queue.yml](../../config/queue.yml) | SOLID_QUEUE_IN_PUMAが存在するとplugin起動（文字列falseも存在する）。Kamal例はtrue、worker既定1 process×3 threads、dispatcher 1秒。実supervisor/heartbeat/通知先は未確認 |
| [filter_parameter_logging.rb](../../config/initializers/filter_parameter_logging.rb)、app/jobs | password/token/key、PDF/答案/下書き等のfilter。jobエラーはID/class中心。全ログやproxy/失敗queue payloadの無漏えい証明ではない。STDOUT/info既定、debug切替・保管期間・アクセス権は要確認 |
| [Dockerfile](../../Dockerfile)、[docker-entrypoint](../../bin/docker-entrypoint) | 通常CMDでdb:prepareが自動実行される。liveで盲目的に起動しない。entrypointを含む実起動経路と承認済みmigration計画を先に確定。秘密値・master.key・環境変数全量を表示しない |
| [production demo](issue93_production_demo.md)、[demo_puma.rb](../../config/demo_puma.rb) | 独立DB/secret/storage/manifest/roles。直接TLSのみ、forwarded headers拒否、trusted proxiesなし、exact Host、Secure/HttpOnly/Strictのhost cookie、readonly business state、reject jobs/null cache。通常学校アプリにそのまま転用しない |

## release gate: 後日、明示承認されたアクセスで採取する読み取り証拠

以下は**未実行**。接続対象・権限・出力先を確認し、read-only DB role/transactionを使う。秘密値・答案・学校名を報告に出さない。

- [ ] 現在のinstance/region、DNS、TLS終端、証明書expiry/chain、HTTPSのみのingress、Caddy有効設定の安全な抜粋。forwarded headerの除去/設定元とRailsのscheme/Host判定、公開HTTP upstream到達可否。攻撃的Host probeは行わない。
- [ ] 稼働container/image digestとbuild commit、web/worker/job登録元すべてのidentity。`docker ps --format '{{.Names}} {{.Image}} {{.Status}}'`、対象imageのdigest/安全なbuild labelだけ。`docker inspect`全量やenv/secrets出力は禁止。
- [ ] 実primary/queue/cache/cableのhost・port・DB名（credential抜き）、PostgreSQL version、schema_migrations、mount source/destination/readonly、`df -h`/`df -i`、backup age/size/checksum/retention/暗号化・アクセス権。
- [ ] 3ログインのSecure属性、HSTSとredirect、健康確認。現在観測したroot404の対象versionとの照合。修正案はstagingで確認後に別承認。
- [ ] 以下queue統計、worker logの安全な件数・reason code、監視担当/通知先/対応記録。実答案や例外本文は貼らない。

### Solid Queue: worker・失敗・滞留（未実行コマンド）

承認済みqueue接続をローカルの安全なlibpq service `qf_queue_ro` に設定し、接続先を先に照合する。新しいRails runnerのboot副作用を避け、SQLをREAD ONLYで実行する。schemaは[queue_schema.rb](../../db/queue_schema.rb)で照合。

```sh
psql service=qf_queue_ro -X -v ON_ERROR_STOP=1 <<'SQL'
BEGIN READ ONLY;
SELECT current_database(), current_setting('server_version');
SELECT kind, count(*), min(last_heartbeat_at), max(last_heartbeat_at)
  FROM solid_queue_processes GROUP BY kind;
SELECT 'ready' AS state, count(*), min(created_at) FROM solid_queue_ready_executions
UNION ALL SELECT 'claimed', count(*), min(created_at) FROM solid_queue_claimed_executions
UNION ALL SELECT 'failed', count(*), min(created_at) FROM solid_queue_failed_executions
UNION ALL SELECT 'blocked', count(*), min(created_at) FROM solid_queue_blocked_executions
UNION ALL SELECT 'scheduled', count(*), min(created_at) FROM solid_queue_scheduled_executions;
SELECT class_name, queue_name, count(*), min(created_at)
  FROM solid_queue_jobs WHERE finished_at IS NULL GROUP BY class_name, queue_name;
COMMIT;
SQL
```

定期観測でready最古時刻/件数の増加、failed増加、heartbeat途絶、claimed長期化、disk/inode逼迫を比較し担当者へ通知する。許容待ち時間・heartbeat閾値・監視頻度は実稼働設定と学校運用で確定し記録する（未確定）。時刻だけで死活や再実行安全性を判定しない。queue DB不通は「0件」ではない。payload/error列は取得しない。
承認済みアプリ環境の補助調査は `RAILS_ENV=production bin/rails 'recovery:candidates[30,100]'` と `recovery:inspect[対象ID]`（読取のみ）。PDF取得を伴う `recovery:eligibility` は対象を限定して別途承認。resume/retry/enqueue/purgeはこの監査の範囲外。

## DB / PDF backup・復元手順案（未実行）

1. 所有者が停止時間、RPO/RTO、保存期間、暗号化保管先、復旧責任者を承認する（現時点未確定）。primaryだけでなくqueue/cache/cableとPDFの対応関係をinventoryに記録。秘密は既存secret manager等で別管理する。
2. 承認された保守窓で新規書込/Job登録を止め、実行中jobをdrainし、PDF upload/purge/cleanupを含む全writer停止を確認する。稼働中のコピーを「整合backup」と称さない。状態不明なら停止して調査しqueue purgeしない。
3. 停止した同じ整合時点で各DBをcustom dumpしPDF volumeをsnapshot/archiveする。例は承認後、既存の安全なlibpq serviceとアクセス制限された空のbackup先で実施する:

   ```bash
   # 未実行。承認済み保守窓で、照合済みinventoryから4変数を設定してから実行。
   (
     set -euo pipefail
     umask 077
     : "${QF_BACKUP_DIR:?absolute empty backup directory required}"
     : "${QF_VERIFIED_STORAGE_ROOT:?absolute storage directory required}"
     : "${QF_APPROVED_BACKUP_DIR:?independently verified canonical backup path required}"
     : "${QF_APPROVED_STORAGE_ROOT:?independently verified canonical storage path required}"
     for qf_path in "$QF_BACKUP_DIR" "$QF_VERIFIED_STORAGE_ROOT" \
                    "$QF_APPROVED_BACKUP_DIR" "$QF_APPROVED_STORAGE_ROOT"; do
       case "$qf_path" in /*) ;; *) echo "Absolute paths required" >&2; exit 1 ;; esac
       test "$qf_path" != / || exit 1
       test -d "$qf_path" || exit 1
     done
     qf_backup=$(cd -- "$QF_BACKUP_DIR" && pwd -P)
     qf_storage=$(cd -- "$QF_VERIFIED_STORAGE_ROOT" && pwd -P)
     test "$qf_backup" = "$QF_APPROVED_BACKUP_DIR" || exit 1
     test "$qf_storage" = "$QF_APPROVED_STORAGE_ROOT" || exit 1
     case "$qf_backup/" in "$qf_storage/"*) echo "Backup inside storage rejected" >&2; exit 1 ;; esac
     case "$qf_storage/" in "$qf_backup/"*) echo "Storage inside backup rejected" >&2; exit 1 ;; esac
     test -w "$qf_backup" && test -r "$qf_storage" || exit 1
     qf_existing=$(find "$qf_backup" -mindepth 1 -maxdepth 1 -print -quit)
     test -z "$qf_existing" || { echo "Backup directory must be empty" >&2; exit 1; }
     # 4 serviceすべてのhost/port/DB/roleは事前に照合。credentialは表示しない。
     for qf_db in primary queue cache cable; do
       pg_dump --dbname="service=qf_${qf_db}_backup" --format=custom \
         --file="$qf_backup/$qf_db.dump"
       test -s "$qf_backup/$qf_db.dump" || exit 1
       pg_restore --list "$qf_backup/$qf_db.dump" > "$qf_backup/$qf_db.contents"
       test -s "$qf_backup/$qf_db.contents" || exit 1
       shasum -a 256 "$qf_backup/$qf_db.dump"
     done
     tar -C "$qf_storage" -cpf "$qf_backup/storage.tar" .
     test -s "$qf_backup/storage.tar" || exit 1
     tar -tf "$qf_backup/storage.tar" > /dev/null
     shasum -a 256 "$qf_backup/storage.tar"
   )
   ```

   `QF_APPROVED_*`は別途レビューしたinventoryのcanonical絶対パスとし、未確認の入力から機械的にコピーして検証を省略しない。4接続先・容量・全writer停止を人間が照合する。失敗時は以後を中断し、不完全backupを成功扱いせず、別の空ディレクトリで原因解決後に再計画する。実接続のDB数/サービス名は現地で確定し、存在しないDBを推測しない。manifestに時刻、source commit/image、migration versions、DB/schema別件数（個人情報なし）、PDF件数/byte、checksum、PG/tool versions、整合停止範囲を記録する。`pg_restore --list`とchecksumだけで復元可能とは主張しない。off-host暗号化copyと復号/読戻し検証を行う。
4. 復元はまず**新規隔離cluster/空DB/空storage**だけ。production credential、外向きAI通信、jobs、メールを無効化し、通常entrypointを実行しない。`pg_restore --exit-on-error --no-owner --no-privileges --dbname=service=qf_restore_primary primary.dump`、対応するqueue/cache/cableを同じ時点から復元し、archiveを空storageに展開する。所有権/grants/sequenceは対象環境用に検証。live DBへの上書き、`--clean`、seed/prepareは行わない。
5. 同一sourceでschema/FK/row count、Blob/AttachmentとPDF実体の対応、checksum、PDF表示、教師判定/点数/Excel、台帳/pointerとqueueの対応を照合。queue復元で実Jobを起動しない。live災害復旧へのcutoverは、この結果と失われる書込範囲をownerが承認後に別計画で行う。

### この段階で提案する合成restore演習

新規task専用cluster/storageに架空学校・架空PDFだけを作り、別の新規空clusterへdump+archiveから復元する。上記manifest/checksum/SQL/FK/添付・読み取り表示・stubbed AIのSystem Specで照合し、成否を証跡化する。実学校backupを持ち込まない。本タスクでは演習自体も未実行。合成演習成功は実インフラbackupの復元成功を意味しない。

コードrefresh: 2026-10-23、上記mainを通常mergeで統合。primaryは17表（14アプリ＋3ActiveStorage）、具象ApplicationRecord14、別DBはcache1/queue13/cable1表。[schema](../../db/schema.rb)と各別DB schemaを静的照合。PR124の図はmain02a8237へmerge済みで本ブランチへ通常統合。[設計図/検証記録](../design/README.md)を再利用し、図の重複編集はしない。main CI39881045679成功は親タスク確認。

### migration / imageの差分確認

[#47 migration](../../db/migrate/20261022100000_create_question_generation_requests.rb)は台帳とAssignment pointer/FK/index、[#46 migration](../../db/migrate/20261022110000_add_processing_claim_to_submissions.rb)はnullable stage/token/claimed_atを追加する。後者はdefault/backfillなし。過去のmigration（processing_generation等）も実稼働schema_migrationsと最終imageを照合して未適用分を確定する。適用済みとは推測しない。

最終imageはRuby4.0.6、Rails8.1.4、PostgreSQL client/libvips、[checksum-pinned qpdf12.4.2 installer](../../bin/install-qpdf)、[Dockerfile](../../Dockerfile)・Gemfile.lock（Mac watchdog用fiddleを含む）を照合する。qpdf installerはLinux/macOS x86_64/ARM64に対応するが全architectureの実行済み証明ではない。実target architectureでfixtureを確認。qpdf exit0/3を受入、限定されたfatal diagnosticは422、runtime/未知失敗は503。入力書換え・完全PDF適合性・暗号化PDF手書きexport対応の保証ではない。PR23のVips化を採用済みとしない。


## release / cutover / rollback checklist（すべて未実行）

- [ ] ownerのAWS配備承認、最終target commit/image digest/CI全4ジョブと変更migration一覧を固定。設定案はstagingで検証。アプリ機能維持を確認。
- [ ] #47: [永続台帳仕様](issue47_durable_question_generation.md)と追加migrationを含む。同文書のAPI中ロック境界の歴史は、merge済み#46の[現行claim仕様](issue46_ai_claims.md)で更新されている。旧web/job登録元を止め、旧generation jobの実行終了・旧queue/Questions/教材状態を調査。旧形式Jobは新コードでAIを開始しない。legacy_unknownを未試行として再送しない。pending/enqueue空白、running中断は自動再実行/age takeover禁止。
- [ ] #46: [PR123](https://github.com/arduino0420/quickflow/pull/123)はmerge済み。[claim protocol](issue46_ai_claims.md)の短transaction→snapshot→lock外AI/PDF→fresh fence/atomic finalizeをweb/worker全体で整合切替。NULL backfill/replay禁止。active/new claimがある間は旧workerへrollbackしない。
- [ ] PDF: [PR122](https://github.com/arduino0420/quickflow/pull/122)のqpdfはmerge済み。実際のinstaller/checksum/CPU architectureを確認し、最終imageのqpdf 12.4.2とfixture preflight、missing runtimeの503をoffline/stagingで検証する。古いimage/未検証ARMへの切替を避ける。通常PDF/warning PDF/pdf-lib生成PDF、保存失敗境界、draft保持を再確認。
- [ ] 上記backupと復元証拠、old process drainと曖昧なlegacy/queued/running workの個別reconciliationを確認後、承認済みmigrationだけを実行して整合したweb/workerへ切替。liveで盲目的db:prepare/db:seed、queue purge、demo auto-rebaselineは禁止。
- [ ] `/up`、ログイン、TLS/cookie/host、mount、worker heartbeat/backlogを比較。合成データの主要フロー/異常系は隔離stagingで行う。#99の[限定合成QA](issue103_submission_evidence.md#99-合成フローの追加証拠2026-10-23)で教師配信/修正/Excel、生徒保存/提出/結果、管理者管理、offline/重複/権限/AI失敗を補足。標準Chromeのadmin手動確認とPDF描画を含むがSeleniumの-32000と旧headless空欄の原因は未解決。公開実環境・実AI・全page/browser/実機は未検証のまま。live認証・変更・AIは別承認。
- [ ] root/login異常、Secure未解決、schema mismatch、missing PDF、権限逸脱、heartbeat消失/滞留増加/予期せぬAI、claim不整合なら新規受付を止め調査。実ログ/DB evidenceで原因判断し、失敗queueや台帳を消さない。
- [ ] rollbackはまず新規write/job/recoveryを停止。旧imageのschema/台帳/claim互換性、queued/running jobと世代を確認。webだけ/imageだけのrollbackは有効な手順ではない。旧web/worker/job登録元の混在禁止。安全を証明できなければmaintenanceを維持しforward fix。新claimを旧workerに処理させない、列/台帳を削除しない。DB+PDF復元は新規書込を失う可能性があるためRPO差分を提示して別承認。学校データと分離デモを混ぜず、manifest不一致はfail closedのまま調査。

#51の監査DoDは上記の実測、整合backup/隔離復元、手動運用方針、公開前確認と復旧条件の証拠で判断する。文書追加だけを実行証拠としない。#99は主要フロー・異常系の既存証拠と今回の限定公開確認、所有者報告、未検証範囲を分けて判断する。本人の提出/通知/学校合格は別条件である。
