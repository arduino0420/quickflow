# Macで編集して確認する開発手順

## 共通の構成

通常版は **compose.yaml 1つ、Caddy・web（Rails/PumaとSolid Queue）・PostgreSQLの3サービス**です。環境値は `bin/dev-docker` がMac開発用に渡します。補助スクリプトに別のサービス定義やCompose生成処理はありません。AWSは同じファイルのproduction既定値と固定リビジョンのイメージ、既存external volume/networkを使います。ゲスト版は別管理のままです。

開発の保存反映には [Compose Watch](https://docs.docker.com/compose/how-tos/file-watch/) を使います。Compose 2.32以降とDocker Desktopが必要です。Macのファイルを開発コンテナへ同期し、Rails developmentが次のリクエストでコードを読み直します。ブラウザは自分で再読み込みしてください。

**Watchが動いている間だけ同期します。** `up -d` だけでは保存しても反映されません。Watchの端末を閉じたりCtrl+Cで終了した場合も同期は止まります。アプリが起動中でも、同期済みの古いコードが残ることがあります。Watchを再開すると `initial_sync` が対象ファイルの最新内容を同期します。

## 初回のMac準備

VS Codeで普段編集するフォルダを開き、Docker Desktopを起動します。

```sh
cd ~/workspace/quickflow
bin/dev-docker build web
bin/dev-docker up -d --wait db
bin/dev-docker run --rm web bin/rails db:prepare
bin/dev-docker up --watch
```

[http://localhost:13000](http://localhost:13000) を開きます。最後の端末は開いたままにし、`Watch enabled` と表示されてから編集を始めます。開発用HTTPのため証明書設定は不要です。ポート変更は `QF_DEV_PORT=13001 bin/dev-docker up --watch` のように指定します。

開発DBはこのフォルダ専用です。本番DB・鍵・PDFをコピーしません。空DBには架空の学校・アカウントだけを[登録手順](operations_details.md#アカウント登録mvp)で用意します。既存の `.env` は開発コマンドでは読みません。開発用session secretはRailsがこのprojectのtmp volumeに独立して生成・保存します。ホストのcredentials、Mac版qpdf、gems、古い `public/assets` は同期しません。通常のアプリへ模擬AIを組み込むこともありません。

## 毎日の起動・停止

```sh
cd ~/workspace/quickflow
bin/dev-docker up --watch        # この端末を開いたまま使う
# VS Codeで保存 → 同期メッセージを確認 → ブラウザを再読み込み
```

Ctrl+CはWatchと、この起動に紐づいたサービスを停止します。別端末から状態確認・停止もできます。

```sh
bin/dev-docker ps -a
bin/dev-docker stop              # DB・PDFのvolumeは残す
```

バックグラウンドで起動したい場合は、次の2コマンドを使います。2つ目の端末は開いたままにし、`Watch enabled` の表示を待ちます。

```sh
bin/dev-docker up -d --wait
bin/dev-docker watch --no-up
```

この場合Watch側のCtrl+Cは同期だけを止め、アプリは起動したままです。最後に `bin/dev-docker stop` を実行します。別フォルダへ移動すると絶対パスから作るproject名が変わり、別DB/PDFが選ばれるため、普段の編集フォルダを変える前に保存先を確認してください。旧開発構成のproject名・DB/PDF/tmp/log volume名は同じフォルダなら維持します。

## 反映方法の違い

| 変更 | 必要な操作 |
| --- | --- |
| Controller・Model・View・JS・CSS | Watch中に保存、同期完了後にブラウザ再読み込み。ビルド不要 |
| Job・採点Service・libなどworkerが使うRuby | 保存・同期後、実行中の仕事の終了を待って `bin/dev-docker restart web`。Solid Queueの別プロセスも再起動 |
| config・routes・importmap・initializer | Watchが同期後にwebを再起動する。進行中の仕事がないときに編集 |
| bin内スクリプト・Gemfile/lock・Dockerfile・OS/qpdf | `bin/dev-docker build web` → `bin/dev-docker up -d --wait` → Watchを再開 |
| Composeや環境値 | Watchを止めて `bin/dev-docker up -d --wait` で再作成し、Watchを再開。restartだけでは設定は変わらない |
| DB migration | ファイルの同期とDB変更は別。下の手順で明示的に実行 |

ファイルがコンテナ内で変わることと、実行中のプロセスが読み直すことは別です。Solid QueueはPumaから起動する別プロセスなので、HTTP側のRails再読込だけでは変更反映を保証できません。`restart web` は処理中Jobへ影響するため、仕事の終了を待ちます。

```sh
bin/dev-docker exec web bin/rails db:migrate
```

migrationは `db/` をWatchしないため、DB変更前に `bin/dev-docker build web` とwebの再作成が必要です。起動時にmigrationを自動実行しません。既存DBへ `db:prepare` を日常的に実行する手順ではありません。`down -v`、volume prune、DB削除、resetは使いません。

## テスト

RSpecはdevelopment DBとは別の `quickflow_test` を使います。本番・開発DBへ `DATABASE_URL` を向けません。RSpecの実AI client生成は禁止されています。

```sh
bin/dev-docker exec -e RAILS_ENV=test web bin/rails db:test:prepare
bin/dev-docker exec -e RAILS_ENV=test \
  -e DATABASE_URL=postgres://quickflow:quickflow-local-only@db/quickflow_test \
  -e QUICKFLOW_GRADING_RECOVERY_ENABLED=false \
  web bundle exec rspec --exclude-pattern 'spec/system/**/*'
bin/dev-docker exec web bin/rubocop
```

system specはChromeが必要です。Macの分離テスト手順かGitHub Actionsを使い、非system成功と全suite成功を区別します。

## 本番確認とAWS反映

本番確認とAWSも同じ `compose.yaml` を使います。`.env.example` は設定名の見本です。実際の秘密値はGitへ入れません。新しい検証用volumeは明示的に準備し、AWSでは既存の名前を照合します。通常の `docker compose up` はproductionで、Watchは開始しません。本番webはコード共有mountなし・root filesystem読み取り専用です。書込みはstorage・tmp・log volumeと `/tmp` に限定します。イメージ内のruntime markerと環境値が食い違う場合は起動を拒否します。

1. Macで実装・保存反映・関連RSpecを検証し、PRと最終コミットのCIを確認する。
2. mainへマージし、確定SHAの追跡ファイルから通常Dockerfileのproduction targetで本番イメージを作る。開発targetを配備しない。
3. ラベルだけでなく実イメージ内コードと確定SHAの内容を照合する。稼働中Job、既存volume/network、バックアップ・復元情報、旧imageと切戻しコマンドを記録する。
4. 既存の配備用environmentとprojectを引き継ぎ、変更が必要な通常サービスだけ更新する。DB/PDFや証明書を作り直さず、共有Caddyのゲスト経路を維持する。migrationは別の明示工程。
5. HTTPS・health・ログイン・assets・queue・DB/PDF保存先・ゲスト到達性を検証する。テスト専用データだけで可能な操作を確認し、スタブ採点と実AIを区別して報告する。
6. Macの未コミット変更を保護してmainをFF更新し、必要なbuild/recreate後にWatchの反映を再確認する。GitHub/AWS/MacのSHAを照合する。

`git pull` だけでは稼働イメージは更新されません。自動デプロイ新設やゲスト版更新は対象外です。バックアップ・切戻しの詳細は[配備手順](issue51_predeployment_runbook.md)と[バックアップ計画](aws_backup_cutover_plan.md)を参照してください。
