# #51 / #99 配備前監査・最小運用手順（未実行の運用案）

監査日: 2026-10-22 UTC。ソース基準: [main 5b5689c9bda13e286b24592e6a49c822ef50b146](https://github.com/arduino0420/quickflow/commit/5b5689c9bda13e286b24592e6a49c822ef50b146)。
[Issue 51](https://github.com/arduino0420/quickflow/issues/51)、[99](https://github.com/arduino0420/quickflow/issues/99)、[提出チェック](issue103_submission_evidence.md)を参照。
本PRは文書のみ。学校アプリの設定変更、AWS/SSH、認証、本番DB/Storage/Queue操作、AI実通信、デモ公開、復元は行っていない。元checkoutの14未コミット項目は読み取り確認のみ。全作業は新規task専用cloneで実施した。

## 確認済みと未確認を分ける

| 対象 | 証拠・判断 |
| --- | --- |
| 現行source | 上記main。#47の永続台帳を含む。実稼働版とは未照合 |
| 歴史的owner handoff | URL `https://13-231-93-159.sslip.io`、commit `a35f2ea54ed10953592283edc73b08321701fbbe`、image `quickflow:pr87-a35f2ea`。現在の稼働identityとは未照合 |
| 公開経路 | 以下の6回のbounded GET/HEADのみ。Caddy応答は確認。EC2 instance、image digest、DB接続先、mount、workerは未確認 |
| CI | [main CI 39763418691](https://github.com/arduino0420/quickflow/actions/runs/39763418691)の1,882例/失敗0・4ジョブ成功は#47/#88の完了記録。提出対象headのChecksは改めて確認する |
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

## 現行コード監査

リンクは上記SHAの各相対パスを照合する。実サーバーの有効設定とは別。

| 根拠 | 所見・次に必要な証拠 |
| --- | --- |
| [production.rb](../../config/environments/production.rb) | 通常profileのassume_ssl/force_ssl/Host例はコメント。外部TLS終端、forwarded headers、HTTP ingress、session secure設定を全体で検証してから変更案を別承認。公開CookieのSecure欠如は解決/再検証が必要 |
| [deploy.yml](../../config/deploy.yml) | server `192.168.0.1`、proxy SSLは雛形。Kamalが実デプロイ経路とは断定しない。storage volumeは`quickflow_storage:/rails/storage`の宣言のみ |
| [storage.yml](../../config/storage.yml)、[database.yml](../../config/database.yml) | 通常productionはDisk `storage/`、primary/cache/queue/cableのPostgreSQL接続。実URL上書き、別host/volume、容量・永続性・backup保管先は不明。DB dumpにはPDFが入らない |
| [puma.rb](../../config/puma.rb)、[queue.yml](../../config/queue.yml) | SOLID_QUEUE_IN_PUMAが存在するとplugin起動（文字列falseも存在する）。Kamal例はtrue、worker既定1 process×3 threads、dispatcher 1秒。実supervisor/heartbeat/通知先は未確認 |
| [filter_parameter_logging.rb](../../config/initializers/filter_parameter_logging.rb)、app/jobs | password/token/key、PDF/答案/下書き等のfilter。jobエラーはID/class中心。全ログやproxy/失敗queue payloadの無漏えい証明ではない。STDOUT/info既定、debug切替・保管期間・アクセス権は要確認 |
| [Dockerfile](../../Dockerfile)、[docker-entrypoint](../../bin/docker-entrypoint) | 通常CMDでdb:prepareが自動実行される。liveで盲目的に起動しない。entrypointを含む実起動経路と承認済みmigration計画を先に確定。秘密値・master.key・環境変数全量を表示しない |
| [production demo](issue93_production_demo.md)、[demo_puma.rb](../../config/demo_puma.rb) | 独立DB/secret/storage/manifest/roles。直接TLSのみ、forwarded headers拒否、trusted proxiesなし、exact Host、Secure/HttpOnly/Strictのhost cookie、readonly business state、reject jobs/null cache。通常学校アプリにそのまま転用しない |

## 後日、明示承認されたアクセスで採取する読み取り証拠

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

   ```sh
   umask 077
   pg_dump --dbname=service=qf_primary_backup --format=custom --file="$QF_BACKUP_DIR/primary.dump"
   pg_dump --dbname=service=qf_queue_backup --format=custom --file="$QF_BACKUP_DIR/queue.dump"
   pg_dump --dbname=service=qf_cache_backup --format=custom --file="$QF_BACKUP_DIR/cache.dump"
   pg_dump --dbname=service=qf_cable_backup --format=custom --file="$QF_BACKUP_DIR/cable.dump"
   tar -C "$QF_VERIFIED_STORAGE_ROOT" -cpf "$QF_BACKUP_DIR/storage.tar" .
   pg_restore --list "$QF_BACKUP_DIR/primary.dump" > "$QF_BACKUP_DIR/primary.contents"
   shasum -a 256 "$QF_BACKUP_DIR/"*.dump "$QF_BACKUP_DIR/storage.tar"
   ```

   全変数は絶対パス・接続先・容量を人間が照合する。実接続のDB数/サービス名は現地で確定し、存在しないDBを推測しない。manifestに時刻、source commit/image、migration versions、DB/schema別件数（個人情報なし）、PDF件数/byte、checksum、PG/tool versions、整合停止範囲を記録する。`pg_restore --list`とchecksumだけで復元可能とは主張しない。off-host暗号化copyと復号/読戻し検証を行う。
4. 復元はまず**新規隔離cluster/空DB/空storage**だけ。production credential、外向きAI通信、jobs、メールを無効化し、通常entrypointを実行しない。`pg_restore --exit-on-error --no-owner --no-privileges --dbname=service=qf_restore_primary primary.dump`、対応するqueue/cache/cableを同じ時点から復元し、archiveを空storageに展開する。所有権/grants/sequenceは対象環境用に検証。live DBへの上書き、`--clean`、seed/prepareは行わない。
5. 同一sourceでschema/FK/row count、Blob/AttachmentとPDF実体の対応、checksum、PDF表示、教師判定/点数/Excel、台帳/pointerとqueueの対応を照合。queue復元で実Jobを起動しない。live災害復旧へのcutoverは、この結果と失われる書込範囲をownerが承認後に別計画で行う。

### この段階で提案する合成restore演習

新規task専用cluster/storageに架空学校・架空PDFだけを作り、別の新規空clusterへdump+archiveから復元する。上記manifest/checksum/SQL/FK/添付・読み取り表示・stubbed AIのSystem Specで照合し、成否を証跡化する。実学校backupを持ち込まない。本タスクでは演習自体も未実行。合成演習成功は実インフラbackupの復元成功を意味しない。

最終refresh: 2026-10-22 11:05 UTC、origin/mainは5b5689c（#41 Selenium 4.51.0更新を統合）。#47の実装と運用設定に差分なし。GitHub fetchでPR122/123はopen、draft、merged=falseを確認。取得head: PR122 `93f2bdc57be0ef95fee0e146ffca458ea611e0b3`、PR123 `165000f8929e4eef1d003e592e9e4e3b28c77e2a`。下記の未マージ条件を維持する。

## release / cutover / rollback checklist（すべて未実行）

- [ ] ownerのAWS配備承認、最終target commit/image digest/CI全4ジョブと変更migration一覧を固定。設定案はstagingで検証。アプリ機能維持を確認。
- [ ] #47: [永続台帳仕様](issue47_durable_question_generation.md)と追加migrationを含む。旧web/job登録元を止め、旧generation jobの実行終了・旧queue/Questions/教材状態を調査。旧形式Jobは新コードでAIを開始しない。legacy_unknownを未試行として再送しない。pending/enqueue空白、running中断は自動再実行/age takeover禁止。
- [ ] #46: [PR123](https://github.com/arduino0420/quickflow/pull/123)は監査時draft/未マージ。実merge後のmigration・nullable reading/grading claim・fence仕様を再読し、web/worker全体を整合切替。NULL backfill/replay禁止。active/new claimがある間は旧workerへrollbackしない。
- [ ] PDF: [PR122](https://github.com/arduino0420/quickflow/pull/122)のqpdfは監査時draft/未マージ。現行main Dockerfileにqpdfなし。mergeされた場合に限り実際のinstaller/checksum/CPU architectureを確認し、最終imageのqpdf 12.4.2とfixture preflight、missing runtimeの503をoffline/stagingで検証する。古いimage/未検証ARMへの切替を避ける。通常PDF/warning PDF/pdf-lib生成PDF、保存失敗境界、draft保持を再確認。
- [ ] 上記backupと復元証拠、old process drainを確認後、承認済みmigrationだけを実行して整合したweb/workerへ切替。liveで盲目的db:prepare/db:seed、queue purge、demo auto-rebaselineは禁止。
- [ ] `/up`、ログイン、TLS/cookie/host、mount、worker heartbeat/backlogを比較。合成データの主要フロー/異常系は隔離stagingで行う。#99の教師配信→結果修正→Excel、生徒PDF→保存→提出→結果、管理者管理、無効入力/回線断/二重送信/AI失敗の証拠は未実施項目を残す。live認証・変更・AIは別承認。
- [ ] root/login異常、Secure未解決、schema mismatch、missing PDF、権限逸脱、heartbeat消失/滞留増加/予期せぬAI、claim不整合なら新規受付を止め調査。実ログ/DB evidenceで原因判断し、失敗queueや台帳を消さない。
- [ ] rollbackはまず新規write/job/recoveryを停止。旧imageのschema/台帳/claim互換性、queued/running jobと世代を確認。安全を証明できなければmaintenanceを維持しforward fix。新claimを旧workerに処理させない、列/台帳を削除しない。DB+PDF復元は新規書込を失う可能性があるためRPO差分を提示して別承認。学校データと分離デモを混ぜず、manifest不一致はfail closedのまま調査。

#51/#99は文書追加だけでcloseしない。実環境の未知項目、backup/restore実証、提出対象CI、公開動作の不足が残る。
