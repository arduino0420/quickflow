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

`COMPOSE_PROJECT_NAME`、image、4つのvolume名が他の作業と重ならないこと、公開先が127.0.0.1であることを確認する。`QF_HTTP_PORT`の初期値18080または`QF_HTTPS_PORT`の初期値18443が使用中なら既存サービスを止めず未使用ポートに変える。秘密値を含む`docker compose config`全文を共有ログへ出さない。

DB/PDF/Caddyは`external: true`のvolumeを明示指定する。空volumeへの意図しない置換を防ぐため、Composeが勝手に作成しない。次は**新規Mac初回だけ**。既存名を検出したら止まり、由来を確認する。既存volumeの初期化や削除はしない。

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
for name in names:
    subprocess.run(docker + ['volume', 'create', name], check=True)
PYVOLUME

docker --context desktop-linux compose config --quiet
docker --context desktop-linux compose build web
docker --context desktop-linux compose up -d --wait db
# 0件であることを確認。既存テーブルがあれば初回準備を止める。
docker --context desktop-linux compose exec -T db psql -U quickflow -d quickflow_production \
  -Atc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"
# 新規の空DBと照合した場合だけ、明示的にschemaを作る。
docker --context desktop-linux compose run --rm --no-deps --entrypoint bin/rails web db:prepare
docker --context desktop-linux compose up -d
```

起動自体に`db:prepare`は含めない。既存本番DockerfileのentrypointはCompose側で無効化し、Thrust→Railsを明示する。将来migrationが増えた場合は、対象DB・変更内容・バックアップを確認して別工程で適用する。単なる再起動にDB変更を混ぜない。

新規DBは空で、既存の学校・生徒・PDFをコピーしない。UI検証用アカウントや教材を作る際も架空データだけにし、本番や普段の開発DBへ向けない。通常構成は架空の採点結果を自動投入しない。

## 日々の編集と再開・停止

```sh
code .
# VS Codeでコードを編集・保存
docker --context desktop-linux compose build web
docker --context desktop-linux compose up -d
# ブラウザ確認。入口は https://localhost:<.envのQF_HTTPS_PORT> 。
docker --context desktop-linux compose ps
# 作業後は停止だけ。volumeやPDFは残す。
docker --context desktop-linux compose stop
# 次回
docker --context desktop-linux compose up -d
```

再ビルドしてもDB/PDFはexternal volumeを継続使用する。Compose名やvolume名を変更すると別データを指し得るので、更新時に勝手に変えない。`down -v`、volume prune、DB drop/resetを日常手順にしない。ソースはimageへ取り込むため、編集直後の自動反映ではない。

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
- AWSは通常版とguestが共有Caddyを使う。今回の通常専用Caddyfileで置換するとguest経路を失うため、**このファイル一式をAWSで無条件にupしない**。入口・ネットワーク引継ぎは[AWS計画](aws_compose_migration_plan.md)の別承認ゲート。

## GitHubからAWSへ進める条件

1. Macの独立checkoutで差分と検証結果を確認し、専用branchからdraft PRを作る。
2. 最終commitのRSpec/system/監査/lint・共通image検証と差分レビューを確認する。
3. ユーザーの別承認後にmainへマージする。普段のquickflowへの取り込みも別承認。
4. 配備commit、Dockerfile/lock hash、image ID/registry digest、CPUを記録し、検証と配備対象を一致させる。再buildした別imageは再検証する。
5. AWSのDB/PDF/queue、backup隔離復元、必要migration、共有Caddyとguest影響、切戻しを確認し、具体的な本番変更の承認を得る。
6. 承認した範囲だけ配備し、本番で機能・保存・jobを確認する。

「ローカル簡素化」「main統合」「普段のフォルダ同期」「AWS適用・稼働確認」は別々に報告する。未確認や保留を残したまま全完了とはしない。
