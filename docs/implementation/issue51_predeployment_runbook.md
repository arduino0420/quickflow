# #51 / #99 配備前監査・最小運用手順（未実行の運用案）

コード更新日: 2026-10-23 UTC。ソース基準: [main 9704b30fa90867a359d11a8ccf0cff78520aa5d2](https://github.com/arduino0420/quickflow/commit/9704b30fa90867a359d11a8ccf0cff78520aa5d2)。公開観測日は下記の2026-10-22のまま。
[Issue 51](https://github.com/arduino0420/quickflow/issues/51)、[99](https://github.com/arduino0420/quickflow/issues/99)、[提出チェック](issue103_submission_evidence.md)を参照。
本PRは文書のみ。学校アプリの設定変更、AWS/SSH、認証、本番DB/Storage/Queue操作、AI実通信、デモ公開、復元は行っていない。元checkoutの14未コミット項目は読み取り確認のみ。全作業は新規task専用cloneで実施した。

## 確認済みと未確認を分ける

| 対象 | 証拠・判断 |
| --- | --- |
| 現行source | 上記main。#47永続台帳、PR123/#46 claim、PR122/qpdf、PR127 Secure Cookie、PR125/#49集約、PR128/83を含む。PR23はVips同等性/Mac test portability未完のためdeferred/draft。実稼働版とは未照合 |
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
- [ ] `/up`、ログイン、TLS/cookie/host、mount、worker heartbeat/backlogを比較。合成データの主要フロー/異常系は隔離stagingで行う。#99の教師配信→結果修正→Excel、生徒PDF→保存→提出→結果、管理者管理、無効入力/回線断/二重送信/AI失敗の証拠は未実施項目を残す。live認証・変更・AIは別承認。
- [ ] root/login異常、Secure未解決、schema mismatch、missing PDF、権限逸脱、heartbeat消失/滞留増加/予期せぬAI、claim不整合なら新規受付を止め調査。実ログ/DB evidenceで原因判断し、失敗queueや台帳を消さない。
- [ ] rollbackはまず新規write/job/recoveryを停止。旧imageのschema/台帳/claim互換性、queued/running jobと世代を確認。webだけ/imageだけのrollbackは有効な手順ではない。旧web/worker/job登録元の混在禁止。安全を証明できなければmaintenanceを維持しforward fix。新claimを旧workerに処理させない、列/台帳を削除しない。DB+PDF復元は新規書込を失う可能性があるためRPO差分を提示して別承認。学校データと分離デモを混ぜず、manifest不一致はfail closedのまま調査。

#51/#99は文書追加だけでcloseしない。実環境の未知項目、backup/restore実証、提出対象CI、公開動作の不足が残る。
