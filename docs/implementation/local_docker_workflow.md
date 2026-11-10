# MacのVS Codeから始める単一Compose運用

## 目的と今回の範囲

**MacのVS Codeで編集 → Dockerで確認 → MacのRSpec → GitHub PR/CI → 別承認でmain → 別承認でAWS** を同じリリースのコードから進める。編集元はMacのローカルcheckoutであり、AWSの作業フォルダから古いコードを戻さない。

通常版はルートの`compose.yaml`1枚と`Dockerfile`を使う。`db`、`web`、`caddy`の3役だけで、profiles、override、用途別サービス、Compose生成は使わない。Caddy → Thrust → Puma/Rails production、Puma内Solid Queue、primary/cache/queue/cableのPostgreSQLとPDF保存が基本構成。開発専用のホットリロードより単純さを優先する。

ユーザーの後続指示で、**guestのローカル環境作成・共通化は今回延期**した。AWSguestは削除・更新・統合しない。通常版の共通化を本番全体の完全一致と呼ばない。

## 初回のMac準備

既存作業を保護した新しいcheckoutで実行する。今回の作業先は`~/workspace/quickflow-single-compose-20261109`。普段の`~/workspace/quickflow`への取り込みは別承認であり、まだ行わない。

Docker Desktop、Docker Compose、MacのRuby/PostgreSQL等の既存テスト環境を使う。`docker --context desktop-linux info`で接続先が自分のMacのDocker Desktopであることを確認する。AWSやremote contextで以下を実行しない。

```sh
cd ~/workspace/quickflow-single-compose-20261109
code .
cp .env.example .env
mkdir -p .local
chmod 700 .local
# 本番の鍵は入れない。初期の通常UI検証ではAPI keyなし。
printf '# Local only: no production credentials\n' > .local/app.env
chmod 600 .local/app.env
```

`.env`へ新規のsecret・image識別・保存volume名を設定する。次は見本を一度だけ新規ローカル値に置き換える例。すでに設定済みの`.env`では実行しない。

```sh
ruby -rsecurerandom -e '
  p = ".env"; text = File.read(p)
  abort "Already configured" unless text.include?("REPLACE_WITH_NEW_RANDOM_HEX")
  token = SecureRandom.hex(4)
  text = text.gsub("quickflow-local", "quickflow-local-#{token}")
    .gsub("quickflow:local", "quickflow:local-#{token}")
    .gsub("REPLACE_WITH_NEW_RANDOM_HEX", SecureRandom.hex(32))
    .gsub("REPLACE_WITH_NEW_128_HEX", SecureRandom.hex(64))
    .gsub("REPLACE_WITH_GIT_COMMIT", "#{`git rev-parse HEAD`.strip}-working-tree")
  File.write(p, text); File.chmod(0600, p)
'
```

`COMPOSE_PROJECT_NAME`、image、4つのvolume名が他の作業と重ならないこと、公開先が127.0.0.1であることを確認する。`QF_HTTP_BIND`の初期値127.0.0.1:18080または`QF_HTTPS_BIND`の初期値127.0.0.1:18443が使用中なら既存サービスを止めず未使用ポートに変える。秘密値を含む`docker compose config`全文を共有ログへ出さない。

DB/PDF/Caddyは`external: true`のvolumeを明示指定する。通常app networkとCaddyの追加接続先もexternal名で指定する。追加接続先はMacでは空のinternal network、AWSでは既存guest networkであり、MacにguestアプリやDBを作るものではない。空volumeへの意図しない置換を防ぐため、Composeが勝手に作成しない。次は**新規Mac初回だけ**。既存名を検出したら止まり、由来を確認する。既存volumeの初期化や削除はしない。

```sh
python3 - <<'PYVOLUME'
from pathlib import Path
import subprocess
values = dict(line.split('=', 1) for line in Path('.env').read_text().splitlines()
              if line and not line.startswith('#'))
docker = ['docker', '--context', 'desktop-linux']
names = [values[k] for k in ('QF_DB_VOLUME', 'QF_STORAGE_VOLUME',
                            'QF_CADDY_DATA_VOLUME', 'QF_CADDY_CONFIG_VOLUME')]
for name in names:
    result = subprocess.run(docker + ['volume', 'inspect', name], capture_output=True)
    if result.returncode == 0:
        raise SystemExit('Existing volume: stop and inspect ' + name)
networks = [values[k] for k in ('QF_APP_NETWORK', 'QF_GUEST_NETWORK')]
for name in networks:
    result = subprocess.run(docker + ['network', 'inspect', name], capture_output=True)
    if result.returncode == 0:
        raise SystemExit('Existing network: stop and inspect ' + name)
for name in names:
    subprocess.run(docker + ['volume', 'create', name], check=True)
subprocess.run(docker + ['network', 'create', networks[0]], check=True)
subprocess.run(docker + ['network', 'create', '--internal', '--opt',
                        'com.docker.network.bridge.inhibit_ipv4=true', networks[1]], check=True)
PYVOLUME

docker --context desktop-linux compose config --quiet
docker --context desktop-linux compose build web
docker --context desktop-linux compose up -d --wait db
# 0件であることを確認。既存テーブルがあれば初回準備を止める。
docker --context desktop-linux compose exec -T db psql -U quickflow -d quickflow_production \
  -Atc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
# 新規の空DBと照合した場合だけ、明示的にschemaを作る。
docker --context desktop-linux compose run --rm --no-deps --entrypoint bin/rails web db:prepare
docker --context desktop-linux compose up -d --wait --wait-timeout 120
```

起動自体に`db:prepare`は含めない。既存本番DockerfileのentrypointはCompose側で無効化し、Thrust→Railsを明示する。将来migrationが増えた場合は、対象DB・変更内容・バックアップを確認して別工程で適用する。単なる再起動にDB変更を混ぜない。

新規DBは空で、既存の学校・生徒・PDFをコピーしない。UI検証用アカウントや教材を作る際も架空データだけにし、本番や普段の開発DBへ向けない。通常構成は架空の採点結果を自動投入しない。

## 日々の編集と再開・停止

```sh
code .
# VS Codeでコードを編集・保存
docker --context desktop-linux compose build web
docker --context desktop-linux compose up -d --wait --wait-timeout 120
# ブラウザ確認。入口は https://localhost:<.envのQF_HTTPS_BIND末尾のport> 。
docker --context desktop-linux compose ps
# 作業後は停止だけ。volumeやPDFは残す。
docker --context desktop-linux compose stop
# 次回
docker --context desktop-linux compose up -d --wait --wait-timeout 120
```

再ビルドしてもDB/PDFはexternal volumeを継続使用する。Caddyだけが2本のnetworkへ接続し、web/dbはapp networkだけを使う。Macは`QF_CADDY_EXTRA_CONFIG=/dev/null`のままにする。Compose名やvolume名を変更すると別データを指し得るので、更新時に勝手に変えない。`down -v`、volume prune、DB drop/resetを日常手順にしない。ソースはimageへ取り込むため、編集直後の自動反映ではない。

## RSpec・品質検査

RSpecはMacのRubyで実行し、専用Dockerfile・Compose・アプリコンテナを作らない。[READMEの分離テスト手順](../../README.md#ローカル起動とテスト)で新規PostgreSQLクラスタと`quickflow_test`を用意し、接続先・クラスタ実体を照合してから実行する。保存先は当該checkoutの`tmp/storage`であり、Docker通常アプリの`/rails/storage`volumeとは別。

READMEの括弧付きテストブロックを**全体で**実行する。新規クラスタ作成 → 実接続照合 → RSpec/品質検査 → 専用クラスタ停止が同じsubshell内で完結する。ブロック外へRSpecコマンドだけを抜き出すと接続URLが引き継がれず、既存の同名DBへ接続し得るため実行しない。再試験も同じ完全な隔離手順から開始する。

実OpenAI clientは禁止した既存RSpec stubを維持する。systemテストのChrome sandboxや証明書検査を弱めない。systemを実行できない場合は非system成功とは分けて報告する。既存GitHub ActionsのRSpec/system、Ruby・JavaScript監査、lintを維持し、Docker確認は同じ通常Composeを使う。旧構成の過去テスト成功を新構成の結果へ流用しない。

## AI・HTTPS・本番との差

- 通常アプリは本番と同じSolid Queueでjobを実行する。API key未設定時の失敗を実AI成功と呼ばない。
- 現AiClientの鍵はRails credentialsの`openai.api_key`から取得する。`OPENAI_API_KEY`を.envへ足すだけでは使えない。実AIは検証用鍵・架空教材・費用上限・範囲の承認後、秘密値供給方法も確認して行う。本番master keyや実生徒答案はMacへコピーしない。
- Macも`https://localhost`を使う。本番のSecure session設定ではHTTPでsessionが発行されずCSRF検証が通らないため、cookie設定を弱めずHTTPSへ揃える。MacはCaddy内蔵CA、AWSの公開hostnameは公開CAを使う。ローカルCAは通常ブラウザから未信頼なので、初回の信頼方法は利用者の判断・明示承認が必要。OSの信頼ストアや通常Chromeは自動変更しない。API/通信検証はCaddyの公開CAだけを指定した専用クライアントで行う。検証専用Chromeの公開鍵限定例外も、対象証明書を照合して別承認後だけ使用する。HTTPの/up成功はログイン成功ではない。
- Mac/AWSとも調査時x86_64だが、Docker VM/Linux、EBS/ローカル保存、ネットワーク、資源、実データ量は異なる。
- 現AWS通常版と最新mainには既存Gem差がある。今回Gemを更新していないことと、現本番と全依存が同一であることは別。
- AWSは通常版とguestが共有Caddyを使う。共通Caddyfileは通常HTTPSと引数付きimportを持ち、AWSは固定 `/etc/caddy/aws-shared.caddy` で現通常HTTP301・guest経路を引き継ぐ。Macは `/dev/null` を選びguestを作らない。Caddyだけがappとguest_routeの両external networkへ接続する。AWS既存経路の意味同値と隔離mock検証は実施したが、実ACME更新・AWS切替は未実施。**ファイル一式をAWSで無条件にupしない**。固定import/引数/CA/host/upstream/ファイルhash/validateを確認し、[AWS計画](aws_compose_migration_plan.md)と[切替計画](aws_backup_cutover_plan.md)の条件を満たす。

## GitHubからAWSへ進める条件

1. コード・Dockerfile・Compose・Caddyfileの修正は必ずMacのVS CodeからGitHubへ送る。AWSの作業フォルダや稼働コンテナで直接編集しない。独立checkoutの差分と検証結果を確認し、専用branchからPRを作る。
2. 最新PRのRSpec/system/監査/lint・共通image検証と差分レビューを確認する。PRの仮merge commitと、承認後に確定するmain commitは区別する。
3. ユーザーの別承認後にmainへマージし、確定main commitのCIを確認する。普段のquickflowへの取り込みも別承認。
4. 配備候補は確定mainの追跡ファイルだけから、未コミット・未追跡・無視対象のローカルファイルを混入させない新しいbuild場所で作る。配備commit、Dockerfile/Compose/Caddyfile/lockのhash、CPU、生成image IDを記録する。本番の秘密やDB/PDFはbuild contextへ入れない。
5. その候補image自体を検証し、固有commit tagとimage IDを記録する。基本案は `docker save` → 既存のホスト鍵照合済みSSH → tar SHA-256照合 → AWSでload → image ID照合。新規registryや常設credentialは必須にしない。最終配布imageの保存・転送は未実施（旧検証imageのMac内save/loadリハーサルは成功）。tar hash/image IDはregistry digestとは区別する。AWSで再buildしたり可変タグだけで選んだりせず、別imageを作ったら再検証する。
6. 同じcommitのCompose/Caddyfileを使用し、AWSとの差は承認済みの環境値・秘密情報・保存先・公開先に限定する。秘密値はGitへ入れず、非秘密の設定仕様はGitで管理する。配備前後にtar SHA-256・固有tagと実image ID、構成ファイルhash、起動コマンド、networkと保存先を記録・照合する。不一致や由来不明があれば自動修正せず停止して調査する。
7. AWSのDB/PDF/queue、backup隔離復元、必要migration、共有Caddyとguest影響、切戻しを確認し、具体的な本番変更の承認を得る。既存共有Caddyの引継ぎが未解決なら配備へ進まない。
8. 前提条件と具体的な通常停止時間・共有Caddyの短時間guest影響を承認後、検証済みの同一imageを保存・転送・照合・loadする。確定project/envを使い `--pull never` / `--no-build` を基本として[切替計画](aws_backup_cutover_plan.md)の個別手順で配備し、本番で機能・保存・job・guest経路と版の一致を確認する。

`QF_SOURCE_REVISION`のimageラベルは識別の補助であり、設定者の自己申告である。ラベル一致だけではソースのclean状態やimage内容の一致を保証しない。ソースからの生成記録、内容hash、tar SHA-256、実image IDと組み合わせる。

**現在のCIは検査と一時的なimage buildまで。配備候補の永続保存・SSH転送・AWS load/適用は未実施。** 2026-11-10の候補Caddy設定は、現AWS原本とのadapt JSON完全同値（Caddy2.11.7）と独立mock HTTPS16項目を確認した。CA欠落はadaptだけでは受理され得るためvalidateと固定import/hash/期待JSON照合が必要。Mac通常HTTPSはHTTP/2 health 200を確認し、web healthcheckと検証コマンドの準備完了待ちを追加した。共有Caddyの起動はwebの健康判定へ依存させないが、変更後の最終QA/CIはこれから。実ACME更新やAWS guest切替疎通は未確認であり、ローカルから本番までの一貫運用完了とは扱わない。

「ローカル簡素化」「main統合」「普段のフォルダ同期」「AWS適用・稼働確認」は別々に報告する。未確認や保留を残したまま全完了とはしない。
