# AWS バックアップ・隔離復元・切替のレビュー用手順

**未実施。実行スクリプトではない。** 条件付きのマージ・配備許可があっても、以下の前提・検証・具体的な通常停止時間と共有Caddy切替による短時間のguest影響が確認・承認されるまで、本番操作を開始しない。記号 `<...>` は未確定項目であり、そのままコマンドへ渡さない。この文書作成時に行ったのは読み取り調査だけ。

対象は通常版3役を単一 `compose.yaml` で管理・更新する移行。guest web/DB/gatewayの3コンテナ、コード、DB、PDF、権限、TLS、namespaceは変更しない。共有Caddyだけは両版の入口なので、guest経路を維持した管理移行が必要。Macの編集→Docker→RSpec→PR/CI→承認main→検証済みAWS成果物の順を守る。

## 1. 着手前に埋める判断欄

| 項目 | 必要な確定内容 |
|---|---|
| リリース | `<DEPLOY_COMMIT>`、CI最終head、テスト結果、Dockerfile/Gemfile.lock hash、通常image IDと配布tar SHA-256、CPU |
| 停止窓 | `<NORMAL_OUTAGE_START/END>`、復元検証を含む通常停止時間、`<GUEST_GATEWAY_OUTAGE_BUDGET>`、中止期限・担当者 |
| 新管理単位 | `<NEW_COMPOSE_PROJECT>`とサーバー上の新releaseディレクトリ。旧projectと別名にして旧containerをComposeの自動削除・再作成対象にしない |
| 保全先 | `<BACKUP_DIR>`、`<RESTORE_DIR>`：サーバー上の新規・専用・空ディレクトリ。既存領域再利用禁止 |
| 停止と受付 | 通常hostだけの受付制御案、処理中Jobの終了待ち上限、worker停止確認方法、期限超過時の中止手順 |
| 秘密供給 | サーバー内の旧実効設定と新envの対応、所有者・permission・欠落チェック。値は報告・Git・ログに出さない |
| 切戻し | 旧container保持、再接続alias、旧image/config、DB/schema互換、受付再開条件 |

新Composeの構成検証・共有Caddy設定の意味同値・guest経路の隔離検証・通常UI検証が必要。ローカルの合成fixtureはAWS実guestの試験や実AI成功ではない。配備用imageを再buildした場合は、その新成果物を再検証する。

## 2. 調査時の保全対象

| 役割 | 現container / image |
|---|---|
| 通常web | `quickflow-deps-20261104-normal-d0fd943` / `sha256:22552b9867b30258a704e116302564549f94a17871fc6ad7380f02adc029853f` |
| 通常DB | `quickflow-db-1` / `sha256:29754c7520f4b9654cf8ff98e19ac73b88e255c3a53f6236ebe9d52249bb6df3` |
| 共有Caddy | `quickflow-caddy-1` / `sha256:f77f856a30f0004200b36b322d61da17fade31e24875699d77fb968399b9eb77` |
| guest web（変更なし） | `quickflow-deps-20261104-guest-d0fd943` / `sha256:c445e48bbc64d5feaa7d33555dcc6f6f7c028fd7eb2fb8d1f7b0b9321b5c35ac` |
| guest DB（変更なし） | `qfguest-public-4c18332acca47671-db-1` / 上記PostgreSQL image |
| guest gateway（変更なし） | `qfguest-public-4c18332acca47671-gateway-1` / `sha256:5fa33078825ec3e496ee93754a3ac6eaeb1e01e3b1bd4d0ff67e789a64f6f83f` |

image IDはregistry digestと区別する。既存通常webはCompose管理外、DBは旧compose.yaml、共有Caddyは旧compose.yaml＋compose.public.yamlの作成元ラベル。旧ファイルのwebは `quickflow:latest` で起動上書きがなく、現webと同一の再作成を保証しない。旧ファイルをそのまま `up` して戻す方法を採用しない。

- DB volume：`quickflow_postgres_data` → `/var/lib/postgresql`、PGDATA `/var/lib/postgresql/18/docker`。
- PDF volume：`quickflow_quickflow_storage` → `/rails/storage`。
- Caddy：`quickflow_caddy_data` → `/data`、`quickflow_caddy_config` → `/config`。
- 通常network：`quickflow_default`、現web alias `web`、DB alias `db`。
- guest接続network：`qfguest-public-4c18332acca47671_isolated`、internal bridge、172.31.241.0/28、inhibit_ipv4=true。guest upstream `172.31.241.2:18443`。
- 共有Caddyは両network接続。TCP80/443をIPv4/IPv6で公開し、UDP443・TCP2019は非公開。再作成でIPv6公開が変わるなら事前に説明・検証する。
- 現通常web：user1000:1000、workdir `/rails`、entrypoint `/rails/bin/thrust`、command `./bin/rails server`、restart unless-stopped、loopback3000→80。PDF volume read-write、memory/CPU/PIDs上限・init・stop timeoutは明示設定なし、logging json-file。新Composeとの差をレビューする。

2026-11-10 00:01:10 UTCのREAD ONLY集計はqueue ready/claimed/scheduled/blocked/failedが各0。通常4DBのSQL容量合計約86.5MiB、PG volume割当約237.8MiB、PDF約3.9MiB。root約29.9GiB中空き約16.8GiB、Docker/backupは同じroot xfs。データ作業用1GiB程度の余裕を見込めるが、image/build/WAL/logは別枠。これは着手時の保証ではなく、再測定が必要。EBS volume/snapshot IDは未確認。

## 3. 読み取りpreflightと秘密情報の保全

1. 上表のcontainer/image/mount/network、旧設定hash、公開port、Git/image/lockの識別を再測定。相違があれば計画を更新してから判断する。
2. 旧通常web・DB・Caddyの実起動設定をサーバー内の限定領域へ保全する工程を承認する。inspect全文は秘密を含み得るのでstdoutやCIログに出さず、保全ファイルは600・親directory700。非秘密の照合結果だけ報告する。
3. 通常appの既存master key、DB password、実効session secret、guest入口URL、grading recovery等と新envの対応をサーバー内だけで照合。環境変数名が同じだけで一致としない。SECRET_KEY_BASEを勝手に再生成しない。供給元が確認できなければ中止する。
4. Caddyfileは `/home/ec2-user/quickflow/Caddyfile`、調査hash `d44eb206e1eae8cf5fd4d4e594ed33a505a6f548979acbe9c25109dbb12695c4`。旧ファイルを上書きしない。共通設定の通常redirect・guest block・CA参照・SNI・Host・header制限が一致するか確認。
5. guestの公開CAは既存Caddy data内 `/data/caddy/qfguest-public-4c18332acca47671/front-ca.crt`。鍵・証明書volumeを保持。guest gateway/web間のTLSもそのまま。CAや秘密鍵を新規生成して本番へ置換しない。
6. 空き容量、4DB容量、PDF量、queue件数を再測定。SQLは正しいDBを識別し `BEGIN READ ONLY` 内で集計。UI個人情報、答案本文、Job引数は読まない。

秘密・DB・PDF・バックアップをMacへコピーしない。backupはサーバー内の700 directory/600 file（umask077相当）とし、実行・復元・読み取りに必要な担当者だけがアクセスする。権限設定も実施時の承認範囲を確認する。

## 4. 受付・worker静止と整合バックアップ（未実行）

1. 検証済みの通常host限定受付制御を適用する。guest hostの経路・レスポンスを変えない。方法は未確定なので、単に共有Caddyを停止して受付停止としない。
2. 通常の新規書込み・Job投入が止まった状態で、ready/claimed/scheduled/blocked/failed、実行worker heartbeat/処理中Jobを確認する。0件へ収束しない場合は意味を確認し、Job削除・強制成功・強制終了で空にしない。設定した待機期限を超えたら中止・受付復帰。
3. queue静止後、通常webを正常停止し、Puma内Solid Queue supervisor/worker/dispatcher/schedulerの停止を確認する。正常停止時間は既定値任せにせず観測に基づく停止猶予を決める。guest3役とDB・共有Caddyは止めない。
4. 他の通常DB/PDF書込プロセスがいないことを確認。停止前後のqueueとDB状態を再測定。app/workerの停止により4DBとPDFの業務書込みを静止させた後、4DBを個別の整合dumpで取得する。稼働書込み下の別々のdumpを跨DB整合backupと呼ばない。
5. 対象は `quickflow_production` / `_cache` / `_queue` / `_cable`、必要なrole/grant定義、PDF storage、manifest/hash、旧実行設定・Caddy設定・証明書保全。role情報やTLSを含むbackupは秘密として扱う。guestのDB/PDFの作り直し・復元はしない。
6. backupのサイズ・終了状態・TOC・SHA-256、生成時刻、元DB/volume識別、queue状態、PDF各ファイルの相対パス・サイズ・hashをサーバー内manifestに記録する。公開ログには件数と成否のみ。dumpを既存DBへ流し込まない。

通常停止を短縮するために書込みを再開するなら、後の切替前に改めて静止・差分のない新backup/検証を用意する。古いsnapshotを最新整合点と扱わない。復元試験を含めた停止予算が不明のまま始めない。

## 5. 新規隔離領域での復元確認（未実行）

1. `<RESTORE_DIR>` が新規・空・実pathで、既存PGDATA/PDF/guest領域やsymlinkを指さないことを確認する。別名の専用PG containerと専用保存先だけを作成する計画をレビューする。
2. PostgreSQLは同じ検証済み18.6 imageを使う。公開portなし、既存app/guest networkに接続しない、専用内部networkまたは適切な隔離方式を選び事前検証。既存volumeをmountしない。資源上限を設定し、本番と競合しない容量/メモリを確認する。
3. **Rails、Puma、Solid Queue、AIを起動しない。** 復元したqueueをworkerへ接続しない。確認用roleは専用cluster内だけとし、本番認証を他サービスへ送信しない。
4. 必要なrole/grantを専用cluster内に復元し、4DBを新規対象へrestore。PDFアーカイブは専用storage領域へ展開し、本番PDFへ上書きしない。終了コードと警告を確認する。
5. 元backup採取時の基準と、migration一覧、各表件数、schema/column/index/FK定義・FK検証状態、sequence値/所有・関連、DB/role/grantを照合。schema_migrationsの最大値だけで成功としない。
6. Active Storage blobのサイズ・checksumと専用復元ファイルを照合。checksum未設定・missing・size/hash不一致を別集計し、未検証を一致扱いしない。PDFアーカイブmanifestと展開後全ファイルmanifestも一致確認する。実答案内容を表示しない。
7. 全項目成功、公開port0、Rails/worker/AI起動0、既存volume使用0を記録する。失敗時は配備せず原因報告。既存データ修正で試験を通さない。試験用container/データの削除も別の明示対象確認なしに行わない。

過去の `/home/ec2-user/quickflow-restore-verification/20261023-pre047ba38/restore-result.json` は4DB・schema/count/FK/sequence・storage manifest・26blob一致をpassedと記録し、Rails/worker/AI起動なし。一方で同所にfailure記録もあり時系列詳細は未照合。`quickflow-backups/current-deploy-backup-path` は10/19を指す。いずれも今回の最新backup・復元可能性の証明ではない。

## 6. 切替順序（前工程成功・停止窓承認後のみ）

1. 再度受付/queue/worker静止とbackupの時点を確認する。通常webの旧containerは停止したまま保持。新旧workerを同時起動しない。必要migrationがあるなら別審査工程に分け、起動へ隠さない。
2. 旧通常DBを正常停止し、PG終了・PGDATA使用プロセス0を確認。新projectの `db` を**既存通常DB volumeだけ**で起動する。旧DB containerは保持。同じPGDATAへの2台同時起動禁止。新DBの実体・4DB・migration・queueをREAD ONLY照合する。
3. 旧停止containerのnetwork endpoint/aliasがDNS競合しないか確認。必要な切離しは対象・旧aliasを記録した上で承認された工程として行う。新DB alias `db` が唯一の稼働対象であることを確認する。既存network自体は消さない。
4. 新projectの通常webだけを、検証済みimage、既存PDF volume、同一実効秘密設定、Thrust明示起動、自動db:prepareなしで起動する。DB依存を理由に意図せず別DBを作成しない。新web alias `web` の接続先、health、worker構成を確認する。失敗時は入口を開かず切戻し判断。
5. 共有Caddyはこの時点まで旧containerを維持する。新Caddyの完全な実効設定・volume・両external network・公開port・guest upstream/CAの一致を事前検証する。単に通常専用Caddyfileで置換しない。
6. 承認された短時間の共有入口停止窓で旧Caddyを停止し、同じ証明書volume・guest接続を持つ新projectのCaddyだけを起動する。旧container/configは保持。公開80/443は二重bindしない。同じ証明書データへ2台Caddyを同時稼働させない。失敗したら即座に新Caddyを止め旧Caddyへ戻す。
7. 通常/guest両hostのTLS、HTTP→HTTPS、Host/SNI、forwarded header拒否、guestへの到達性を検証。guestの3コンテナ・image・mount・network namespaceが変更されていないことを確認。guestへの新しい試験書込みや実AIは行わない。
8. 通常のログイン/PDF/手書き/下書き/提出/教師修正/Excel/永続性の受入範囲を、承認済みの検証アカウント・架空教材で実施する。実AIが未承認なら通信させず、その項目は未確認と記録する。単なる/up成功で完了にしない。
9. 中止条件がなく、通常入口・worker・guest経路が正常なら受付を再開。再開時刻と切替後書込み開始を記録する。旧container/image/config/backupを保持し、勝手な整理・pruneをしない。

新projectへの移行は管理ラベルの変更を伴う。実施するComposeコマンドは承認されたrelease directory・project・env・serviceを明示し、操作ごとに依存サービスへの波及を確認する。全体 `up/down` を一括投入せず、上記順序を満たす検証済み個別操作に落とし込んでから実行する。

## 7. 切戻し・中止条件

- 新Caddy失敗：新Caddyを停止、旧Caddyの保持済みconfig/volume/両network/portで再開。guest入口の復旧を先に確認する。CAやguest gatewayを作り直さない。
- 新通常web失敗：通常受付を閉じたまま新webを正常停止しworker終了確認。schema互換とDB状態に問題がなければ、新DBを維持して旧webを戻す案、または新DB停止後に旧DBを同じ既存volumeで再開する案を事前に選ぶ。aliasの重複を解消し、旧webの保存済み実行設定を復元する。
- 旧DB再開：新PGが完全停止していることを確認し、同一PGDATAへ旧PGを1台だけ起動。旧image/設定/volumeを再照合する。旧webのThrust直起動を維持し、旧compose.yamlの曖昧なlatest起動で代用しない。
- schema変更後、または受付再開・受入試験で新しい書込みがあった場合、旧imageへ戻せるか個別判定する。**自動DB/PDF復元は禁止。** 失われ得る更新と整合範囲を説明し、復元は別判断・承認とする。
- guest経路断、namespace/alias混乱、volume/DB識別不一致、容量不足、復元不一致、未知のschema差、queue静止不能、秘密供給不明、未承認AI通信の恐れ、停止予算超過で中止する。
- `prune`、`down -v`、`db:drop`、`db:reset`、既存volume/backup削除、実データ上書きを復旧手順にしない。

## 現在の完了区分

読み取り実測とこのレビュー用計画だけ完了。最新backup作成、隔離restore、受付停止、通常/共有Caddy切替、実AWS受入は未実施。停止時間・受付制御・新project/alias切替・秘密供給・配布imageとCIの一致を確定するまで実行段階に進まない。
