# 単一 Compose の AWS 移行計画（未実施・別承認）

日常の流れは **Mac の VSCode で編集 → 共通 Dockerfile で再ビルド → Docker で動作確認 → Mac の分離した RSpec と GitHub PR/CI → 承認後 main → 別承認後 AWS** とする。通常運用の Compose はルートの `compose.yaml` 1枚、今回のサービスは通常版の `web/db/caddy` の3役。ユーザーの最新指示によりguest実行環境の共通化・ローカル作成は延期した。用途別 dev/check/test、override、YAML生成は使わない。

この文書は2026-11-09の読み取り実測と作業中の共通Composeを基にしたレビュー用計画であり、実行済みの配備手順ではない。**AWSの起動・停止・設定変更・migration・配備には具体的な計画の再確認と別承認が必要。** 稼働中のCompose/Caddyfileは削除・上書きしない。ローカル簡素化、main統合、普段のフォルダへの取り込み、AWS適用の完了は分けて判定する。

## 今回の範囲と本番配備ゲート

最終目標は、AWS通常版のRails・PostgreSQL・共有Caddyも、Macを編集元とするGit管理の `compose.yaml` 1枚から再現・更新できる状態にすること。共有Caddyはguestの入口も保持し、guestのweb/DB/gateway自体の移行は今回の対象外とする。移行中は現在のCaddyを保全し、両公開経路を引き継げる単一ComposeとCaddyfileを検証してから、別承認した順序で3役の管理元を揃える。通常版の別Composeや手動 `docker run` を恒久的に併用する完成形にはしない。

**現 `docker/Caddyfile` は通常版のみ。これをAWSの共有Caddyにそのまま適用するとguest公開経路が失われるため、置換・reload・新Caddy起動による入口切替を禁止する。通常版のコード/image/DB構成を共通化しても、AWS入口の引継ぎは未完了であり、本番全体の単一Compose化完了とはしない。**

次回は既存の共有Caddyを保持したまま、新通常webと既存ネットワークをどう接続するかを個別に設計・承認する。現Composeの `app` ネットワークは新規作成なので、既存共有Caddyが自動で新webへ到達できるとは限らない。既存alias `web` の競合・切替、公開ポート、TLS、guest経路維持を検証してから配備可否を判断する。現ComposeをAWSでそのまま `up` する手順は未承認・未検証。

ローカルguest用の途中成果は非公開の延期用保管場所へ移し、実行対象・PR対象から外す。guest DB・containerの新規作成は0件。既存AWS guestのimage/DB/storage/設定/稼働はそのまま保持する。

## 共通条件と残る違い

- 通常版で共通化する対象はComposeのアプリ/DB構成、Dockerfile、リリースのコード・Gemfile.lock、Thrust → Puma/Rails production、Puma内Solid Queue、PostgreSQL、PDF永続化。共有Caddyへの本番接続は上記ゲートが残る。RSpecはこの通常起動構成の外で、テストDB・テスト保存先に隔離する。
- Macは新規の架空データ・独立した秘密情報・loopback公開。ローカル入口もSecure sessionを維持するためHTTPSを使う。MacはCaddy内蔵CA、AWSは公開CAという証明書発行元の違いがある。ローカルCAの信頼設定をOSや通常ブラウザへ自動追加しない。AWSは既存DB/PDF・本番秘密情報・公開HTTPSを保持する。実AI通信は検証用キー、架空教材、費用上限、範囲の承認まで行わない。
- guestのMac実行環境作成は延期した。AWS guestの旧image・旧schema・manifest・保存先は保持し、guestの同一構成・同一コードを達成したとは報告しない。将来再開する場合も、新しい架空データでのローカル検証と既存AWS guest更新は別の判断とする。
- 調査時のMac/AWSはともにx86_64。ただしOS、保存装置、資源、実データ量は異なる。別CPU向けの再ビルドは別成果物として検証する。

## 1. 現稼働を正とする

AWS作業フォルダ `/home/ec2-user/quickflow` のHEADは `a8816b66ecde35695b1a0661d0c6c492afda39be`。Compose/Caddyfileは未追跡で、DB/共有Caddyに古いCompose管理ラベルがある一方、現在の通常/guestアプリは個別差し替え済みでCompose管理外。作業フォルダHEADや残存Composeのimageを現稼働版とみなさない。

| 役割 | 現稼働コンテナ / 識別子 |
|---|---|
| 通常web | `quickflow-deps-20261104-normal-d0fd943`。image `sha256:22552b9867b30258a704e116302564549f94a17871fc6ad7380f02adc029853f`。revision label `c2e1d529b976d0d2984ce6830eed4517d3e1f567` |
| guest web | `quickflow-deps-20261104-guest-d0fd943`。image `sha256:c445e48bbc64d5feaa7d33555dcc6f6f7c028fd7eb2fb8d1f7b0b9321b5c35ac`。revision label `guest-issue186-5013600c6414` |
| PostgreSQL（両版） | 18.6。image `sha256:29754c7520f4b9654cf8ff98e19ac73b88e255c3a53f6236ebe9d52249bb6df3` |
| 共有Caddy | v2.11.7。image `sha256:f77f856a30f0004200b36b322d61da17fade31e24875699d77fb968399b9eb77` |
| guest gateway | v2.10.2。image `sha256:5fa33078825ec3e496ee93754a3ac6eaeb1e01e3b1bd4d0ff67e789a64f6f83f` |

### Composeファイルと現在の管理範囲

- guest DB `qfguest-public-4c18332acca47671-db-1` とgateway `qfguest-public-4c18332acca47671-gateway-1` の `com.docker.compose.project.config_files` は `/home/ec2-user/quickflow-guests/qfguest-public-4c18332acca47671/compose.json`。YAMLではなくJSON形式のComposeで、projectは `qfguest-public-4c18332acca47671`、serviceはそれぞれ `db` / `gateway`。
- 現guest web `quickflow-deps-20261104-guest-d0fd943` にはCompose管理ラベルがない。上記JSONにweb定義は残るが旧imageであり、現webを含めて一括管理する正しい起動定義とは扱わない。現在のwebを作成した実コマンドは今回未確認。
- 共有Caddy `quickflow-caddy-1` のラベルは `/home/ec2-user/quickflow/compose.yaml` と `/home/ec2-user/quickflow/compose.public.yaml` を指す。projectは `quickflow`、serviceは `caddy`。`/home/ec2-user/quickflow/Caddyfile` を `/etc/caddy/Caddyfile` にbindしている。これは通常版とguestの共通公開入口。
- guest gatewayは別の `/home/ec2-user/quickflow-guests/qfguest-public-4c18332acca47671/Caddyfile` を使用する。共有Caddyと取り違えない。

通常DB `quickflow-db-1` のラベルはproject=`quickflow`、service=`db`、config_files=`/home/ec2-user/quickflow/compose.yaml`。通常RailsにはCompose管理ラベルがなく、`quickflow_default`のalias `web`に接続し、共有Caddyは `web:80`へ転送している。通常版に関係する稼働はこの3コンテナで、Caddyはguest共用。観測時のAWS全体はguest側3コンテナを含め6コンテナだった。

ラベルはコンテナ作成時の管理元を示すもので、ファイル内容が現在の全コンテナに一致することや安全に更新できることを保証しない。**通常AWSのCompose本文・web定義は今回未読**で、現Railsのimage/起動設定との一致は未確認。具体的な切替前に秘密値を公開せず本文と実稼働を照合し、正しい単一Composeへ取り込む設計を確定する。ここに挙げたAWSファイルは今回いずれも変更・再実行していない。

上記sha256はDockerのローカルimage ID。registryのRepoDigestと混同せず、移送する場合は配布可能なdigestと対応を別途記録する。guestの残存compose.jsonはさらに古いweb image `a097...` を参照しているため、そのまま再起動しない。

### コード・Gem・DBの差

両稼働appはRuby4.0.6、Rails8.1.4、OpenAI0.106.0。調査時main `fe607634ef75f1f7d6a4fd1b130f3720ddc86cb4` はRails8.1.4.1、OpenAI0.115.0。これは既に存在する差であり、今回新たにGemを更新する理由にはしない。通常/guest/配備候補それぞれの完全なコード・Gem差分レビューは配備前の残作業。

- 通常Gemfile.lock SHA-256: `2fa58c8961d7726930a219811142de08e027dbd48a9b1056d1a879baaec65fe1`
- guest Gemfile.lock SHA-256: `9e9755acf8c6c0e4f8cdeba43abbe9d60b658d57b04b5f015641a0d51b356845`
- 調査時main Gemfile.lock SHA-256: `cc157879453690700dfc84722a5f1068af7fc1cb4289aa88982c0009045fab1c`
- 通常のschemaファイルは調査時mainと一致（SHA-256 `8c3be41c24c59826bf270ed4fb3c33ead25a8c52d5226617eb8b59a2ca91555a`）。実DBのmigration末尾は`20261026090000`。schemaファイル一致だけで実DB定義全体の一致を保証しない。
- guest実DBのmigration末尾は`20261022110000`。schemaファイルSHA-256 `79dcdb8ecc6dfbda30301cf3000434bd2939e947e4463ccc677c318b1099c884`。grading recovery列追加前の版を保持しており、新mainで自動migration・再seed・manifest更新をしない。
- `bin/demo-web` と `lib/demo/profile.rb` は稼働両版と調査時mainで同じファイルハッシュ。ただしこれだけでguest全体の互換性を証明しない。

## 2. 既存データと設定値の対応

以下は**別承認後の移行設定の候補、未適用**。値を設定するだけでは移行完了にならない。秘密値はGit、文書、CIログ、build contextに入れない。

| Compose変数 | AWSで保持する対象 |
|---|---|
| `QF_IMAGE` / `QF_SOURCE_REVISION` | 新しい配備候補の検証済みimageとGit commit。`latest`だけで識別しない |
| `QF_POSTGRES_IMAGE` | 上記両版PostgreSQL image ID。設定例: `sha256:29754c7520f4b9654cf8ff98e19ac73b88e255c3a53f6236ebe9d52249bb6df3` |
| `QF_CADDY_IMAGE` | `sha256:f77f856a30f0004200b36b322d61da17fade31e24875699d77fb968399b9eb77` |
| `QF_DB_VOLUME` | `quickflow_postgres_data` → `/var/lib/postgresql`（PGDATA `/var/lib/postgresql/18/docker`） |
| `QF_STORAGE_VOLUME` | `quickflow_quickflow_storage` → `/rails/storage` |
| `QF_CADDY_DATA_VOLUME` / `QF_CADDY_CONFIG_VOLUME` | `quickflow_caddy_data` / `quickflow_caddy_config` |
| `QF_SITE_ADDRESS` | `https://13-231-93-159.sslip.io`。HTTP→HTTPS転送も検証 |
| `QF_BIND_ADDRESS` / `QF_HTTP_PORT` / `QF_HTTPS_PORT` | `0.0.0.0` / `80` / `443`。現在のIPv6公開との差も確認 |

通常DBはprimary/cache/queue/cableの4DBを保持。guestは `quickflow_demo_4c18332acca47671` の別DB、別権限、別manifest。既存匿名volumeも今回削除しない。

`QF_DB_PASSWORD`、`QF_SECRET_KEY_BASE`、`QF_APP_ENV_FILE`はサーバー内の限定権限ファイルで管理する。通常appの既存master key/API keyはそのままサーバー内で供給し、Macへコピーしない。新ComposeのSECRET_KEY_BASE明示設定は既存の実効値との対応確認が必要で、勝手な再生成によるsession失効を避ける。guest runtimeへ渡すのは独立DB URLとsession secret等だけで、通常master key/API key/provisioning権限を混ぜない。

guest DBのbootstrap-password mount等は現状維持。今回guestのenv_fileや設定は作成・切替しない。

Docker volumeとguest bind先は実測時どちらもroot `/dev/nvme0n1p1`（xfs）。**EBS volume ID、snapshot ID、snapshotの整合性は未確認**。volume名やディレクトリの存在だけでバックアップ済みと扱わない。

## 3. 既存guestの安全境界（実測参考・今回変更しない）

以下は既存AWSの保護対象。今回の3役Composeに実装した機能ではない。

- guest_dbはinternalネットワーク内の固定IPを持ち、PostgreSQLはloopbackの55445のみでlisten。guest_webとguest_gatewayは `network_mode: service:guest_db` で同じnamespaceを共有する。
- 共有Caddy → guest固定IP:18443のgateway → loopback:18443のPuma。両段TLSで証明書・サーバー名を検証する。共有Caddyとguest gatewayのCAは役割が異なる。
- 両Caddyの64KB body制限、Forwarded/X-Forwarded-For/Proto/Host、X-Real-IP、X-Url-Scheme、Front-End-Httpsの拒否と上流への除去を保持。上流接続2、dial 2秒、response header 10秒の制限を保持する。厳密な同時リクエスト数2と説明しない。
- gatewayはadmin/自動HTTPS/config永続化をOFF、read header 5秒・body 10秒・idle 15秒、header 16KB制限を維持。
- guestは `bin/demo-web`、0 worker、AI/ジョブ/secondary DBなし、readonly storage/control/rootfs。`SOLID_QUEUE_IN_PUMA`はfalseでも存在自体が拒否されるため設定しない。
- cap_drop ALL、no-new-privileges、logging none、uidとtmpfsを保持。現資源上限はweb384MiB/0.25CPU/PIDs100、gateway96MiB/0.25CPU/PIDs40、DB384MiB/0.5CPU/PIDs80。稼働restart policyはno。将来移行時にも無説明で変更しない。
- 旧guestの `/proof` 監査mountも今回は保持する。将来整理する際は起動・監査コマンドの参照を確認する。

## 4. 配備前の残作業と実行順（すべて別承認後）

1. [Mac起点の配備条件](local_docker_workflow.md#githubからawsへ進める条件)に従い、承認後の確定main commit、コード/Gem/schema差分、追跡ソースから生成・検証したimage ID/registry digest、CPU、Dockerfile/Compose/Caddyfile/lockのhashを確定する。現在はimage保存・配布工程が未実装なので、承認済みの配布先と取得方法が確立するまで配備へ進まない。AWSではコードや構成を直接編集せず、同じcommitの構成と同じ検証済みimageを使用し、再buildしない。設定値以外の差分や識別不一致は停止条件とする。
2. 読み取りpreflightで現container/image/mount/network/公開ポート/設定指紋を再測定。通常queueのready/claimed/scheduled/blocked/failedは2026-11-09観測時すべて0だったが、切替直前に再測定する。処理中ジョブの終了待ち、受付停止、タイムアウト時中止条件を決める。
3. DBとPDFを整合した時点でバックアップし、**隔離した保存先で復元確認**する。過去のbackup/restore-verificationディレクトリは存在したが、この移行用の復元試験はまだ行っていない。EBS識別とsnapshotを含め保全範囲を記録する。
4. 既存共有Caddyを保持する入口引継ぎ・ネットワーク接続計画を別途承認してから、新しいreleaseディレクトリへ通常版Composeと検証済み設定を置く。旧作業フォルダのCompose/Caddyfileを上書きしない。external volumeとbind先の実体・所有者・DB/system identifier/guest manifestを照合する。空の置換volumeを作らない。
5. 共通Composeの通常webはentrypointを空にしてThrustを明示し、自動 `db:prepare` を回避する。必要migrationを差分から別工程として審査・承認し、guest旧DBへ実行しない。調査時schema差がないことを将来の配備commitへ流用しない。
6. 停止対象と停止時間を合意し、新旧workerが同じqueueを同時処理しない順序で通常版を切り替える。旧コンテナ/image/設定を保持する。DBを同じPGDATAで二重起動しない。
7. guestの3コンテナ・namespace・subnet・保存先は切り替えない。通常版の新ネットワークと既存共有Caddyの接続方法、alias衝突、切替時の到達性を別途確定する。既存ネットワークを無承認で削除しない。
8. 既存共有Caddyと証明書volumeを保持する。通常版だけの `docker/Caddyfile` に置換しない。入口の変更が必要ならguest経路・CA・公開TLS・SNI・Host・header境界・HTTP転送を維持する具体的な変更内容を別途承認し、両経路を検証する。
9. HTTPS、ログイン、PDF、手書き、下書き、提出、採点queue、教師修正、Excel、再起動後の永続性、guest各roleの閲覧・書込拒否・no-AI/no-jobを確認する。実AIは別途承認範囲のみ。`/up`の200だけで受入完了にしない。

安全な読み取りpreflightの例（秘密値を含む `docker inspect` 全文や `docker compose config` 全文を共有ログへ出さない）:

```sh
# AWSで読み取り許可済みのセッションに限る。変更コマンドではない。
sudo docker ps --format '{{.Names}} {{.Image}} {{.Ports}}'
sudo docker inspect --format '{{.Name}} {{.Image}} {{json .Mounts}}' <確認対象container>
sudo docker network inspect --format '{{.Name}} {{.Internal}} {{json .IPAM.Config}}' <確認対象network>
# queue/schema照合は接続先を確認し、BEGIN READ ONLY内のSELECTだけで行う。
```

## 5. 切戻しと中止条件

- 切替前に旧image ID・実起動設定・network alias・namespace・TLSと保存先の対応を保持し、旧通常webを戻す順序と、保持した既存共有Caddy・guest経路に影響しないことを確認する。Dockerの同じ名前や固定IPの競合を解消する工程を計画に含める。
- schemaを変更しない構成移行では旧image/設定へ戻す。schema変更が加わる場合は旧コード互換を先に確認し、単なるimage rollbackでよいと決めつけない。
- データ復元は切替後の更新を失う可能性があるため自動実行しない。復元範囲と損失を説明し別判断を得る。既存volume削除、DB初期化、PDF上書き、`down -v`、pruneを切戻しに使わない。
- DB/volume識別不一致、未確認の復元、未知のschema差、namespace/subnet競合、queue静止不能、guest権限/manifest/TLS変化、未解決テスト失敗、secretや架空AIの混入、承認範囲外の操作があれば中止する。

**現在: 通常版3役への範囲縮小と読み取り実測・移行設計まで。guest共通化は延期、AWS入口引継ぎは未完了。AWSで新Composeの起動、停止、migration、backup作成、復元、切替、受入試験は未実施。ローカル成功やPR/CI成功をAWS適用完了として扱わない。**

## 参考: 延期した6役案（今回の実装・配備対象ではない）

将来guest共通化を再開するときの案は `web/db/caddy/guest_web/guest_db/guest_gateway` の6役。guest用途はdev/check/testの検証環境ではなく実際の提供機能である。以下の `QF_GUEST_*` は延期案の対応名であり、現3役Composeの有効な設定変数ではない。設定するだけではguestは起動しない。

| 延期案の変数 | 読み取り時のAWS対象 |
|---|---|
| `QF_GUEST_IMAGE` | 上記現稼働guest image ID（更新しない） |
| `QF_GUEST_CADDY_IMAGE` | `sha256:5fa33078825ec3e496ee93754a3ac6eaeb1e01e3b1bd4d0ff67e789a64f6f83f` |
| `QF_GUEST_ID` | `4c18332acca47671e27c96b65fc45d91` |
| `QF_GUEST_HOST` | `qfd-4c18332acca47671.13-231-93-159.sslip.io` |
| `QF_GUEST_SUBNET` / `QF_GUEST_DB_IP` | `172.31.241.0/28` / `172.31.241.2` |
| `QF_GUEST_DB_PORT` / `QF_GUEST_HTTPS_PORT` | `55445` / `18443` |
| `QF_GUEST_DB_USER` | `qfd_bootstrap`（新規ローカル値と混同しない） |

guestのAWSルートを以下では `G=/home/ec2-user/quickflow-guests/qfguest-public-4c18332acca47671` と表記する。**Gは説明用でありComposeが展開する変数ではない。実envでは完全な絶対パスを指定する。**

- `QF_GUEST_DATA_DIR`: `G/pgdata` → `/rails/tmp/production-demo-pg-<QF_GUEST_ID>`
- `QF_GUEST_CONTROL_DIR`: `G/release-4667c7c/guest/control` → `/rails/tmp/production-demo-control-<QF_GUEST_ID>`（読取専用）
- `QF_GUEST_STORAGE_DIR`: `G/release-4667c7c/guest/storage` → `/rails/tmp/production-demo-<QF_GUEST_ID>`（読取専用）
- `QF_GUEST_GATEWAY_TLS_DIR`: `G/gateway-tls` → `/proof-tls`（読取専用）
- `QF_GUEST_CA_FILE`: 既存公開CAの内容・指紋を照合したサーバー内ファイル。現共有Caddyは `/data/caddy/qfguest-public-4c18332acca47671/front-ca.crt` を使用し、旧app監査mountには`G/authority/front-ca.crt`がある。両者の一致を未確認のまま代用しない。秘密鍵はMacへ持ち出さない。


再開時はguest DB変更に伴うweb/gateway namespaceの同時切替、旧subnetとの衝突、既存manifest・DB権限・readonly保存先・両段TLSを再検証する。旧imageを新mainへ差し替える承認を含めず、今回はいずれも実施しない。
