# Macで編集して確認する開発手順

## 使い分け

- **普段の開発**：`bin/dev-docker`。Macで保存したコードを共有し、Railsのdevelopment（開発モード）で読み直します。
- **本番と同じ動きの確認・AWS**：従来の`compose.yaml`と本番イメージ。ソースをイメージに固定し、更新時に再ビルドします。

`compose.development.yaml`は明示的に選んだときだけ使います。自動読込される`compose.override.yaml`ではありません。AWSで通常の`docker compose`を実行しても開発設定は入りません。通常版の3役（Caddy、Rails/Puma、PostgreSQL）を維持し、ゲスト版は変更しません。

READMEに残っている`docker compose up`/`stop`は**本番モードの確認用**です。日常のコード編集には以下の`bin/dev-docker`を使ってください。

## 初回のMac準備

Docker Desktopを起動し、VS Codeで普段編集するQuickFlowフォルダを開きます。以下は`~/workspace/quickflow`の例です。別の場所にcloneした場合はその場所へ移動します。

```sh
cd ~/workspace/quickflow
bin/dev-docker build web
bin/dev-docker up -d --wait db
bin/dev-docker run --rm web bin/rails db:prepare
bin/dev-docker up -d --wait
```

[http://localhost:13000](http://localhost:13000)を開きます。開発用HTTPなので自己署名証明書の受入は不要です。本番のHTTPS・Secure Cookie設定は変更していません。

DBは開発専用の新しい保存領域です。学校・アカウント・PDFは自動コピーしません。[アカウント登録](operations_details.md#アカウント登録mvp)を参照して架空のデータを用意してください。登録操作も`bin/dev-docker exec web bin/rails console`など**同じ開発コンテナ内**で行います。

`.env`の用意はこの開発構成では不要です。既存の`.env`、本番用の鍵、既存DB、既存PDFはそのまま残します。本番の鍵をコピーしないでください。開発構成はホストのRails credentialsも読み込みません。実AI呼出しはこの手順では使えず、AI関連テストはスタブ（代役）を使います。

## 毎日の操作

```sh
cd ~/workspace/quickflow
bin/dev-docker up -d --wait       # 再開
bin/dev-docker ps                # 状態確認
# VS Codeで保存し、ブラウザを再読み込み
bin/dev-docker stop              # 終了。DBやPDFは残る
```

ポート13000が使用中なら、各コマンドの前に`QF_DEV_PORT=13001`を付け、http://localhost:13001を使います。

`bin/dev-docker`はMacのDocker Desktopだけを選びます。フォルダの絶対パスから専用プロジェクト名を作るため、検証用の別フォルダとDB・PDFが混ざりません。フォルダを移動すると別プロジェクトになるので、保存先を変更する前に確認してください。停止したコンテナも含めて見るには`bin/dev-docker ps -a`です。

## 何を変更したら何をする？

|変更|操作|
|---|---|
|Controller、Model、通常のService、View|保存してブラウザ再読み込み|
|`app/javascript`のJavaScript、`app/assets/stylesheets`のCSS|保存してブラウザ再読み込み。importmap/Propshaftが配信し直すためNodeのビルドは不要|
|画像など`public`配下|保存して再読み込み。ブラウザキャッシュが残る場合は強制再読み込み|
|Job、採点Serviceなどバックグラウンド処理で使うコード|実行中の仕事が終わってから`bin/dev-docker restart web`。Puma内Solid Queueも再起動|
|initializer、`config`、routes/importmapの大きな変更|確実に反映するには`bin/dev-docker restart web`|
|Gemfile/Gemfile.lock、Dockerfile、OSパッケージ|`bin/dev-docker build web`の後に`bin/dev-docker up -d --wait`|
|Composeの環境値・マウントなど|`bin/dev-docker up -d --wait`で再作成（restartだけでは設定を更新しない）|
|DB migration追加|下記のmigration手順|

バックグラウンド処理は別プロセスで動くため、ブラウザ再読み込みだけに依存しない運用にしています。処理途中のJobがある間は再起動を避けます。

### DB migration

```sh
# 対象はこの開発プロジェクトのDB。変更内容を確認してから実行。
bin/dev-docker exec web bin/rails db:migrate
```

既存データを変更するmigrationでは、先にバックアップを取り、影響を確認します。`db:reset`、`db:drop`、`down -v`、volume pruneは通常手順では使いません。起動時に自動migrationはしません。

## 反映される仕組みと保存先

- **バインドマウント**：Macのソースフォルダをコンテナの`/rails`から見えるようにします。保存したファイルが即座に共有されます。
- Railsはdevelopmentでコードを再読み込みします。Docker VM越しのファイル通知に依存せず変更を確認します。
- Gemはソースとは別の`/usr/local/bundle`に置くので、マウントで隠れません。
- Macの既存`public/assets`は削除せず、コンテナ側だけ空の一時領域で覆います。古い本番用コンパイル済みファイルが開発配信を邪魔しません。
- qpdfもMac版を実行せず、イメージに組み込んだLinux版をリンクで参照します。
- DB、PDF、ログ、tmpは開発プロジェクト専用volumeです。通常版/本番確認用の既存volumeやMacネイティブPostgreSQLには接続しません。
- Solid Queueは開発用queue DBを使います。本番と同じくPumaに付属して起動します。実AI成功と、スタブを使ったテスト成功は区別します。

## テスト

開発コンテナには既存のdevelopment/test Gemと、JavaScriptの自動テスト用Node.js、プロセス検査用psが入ります。テスト用DBは同じ**開発専用PostgreSQLコンテナ**内の`quickflow_test`です。本番に向けないでください。既存テストの安全確認がこのDB名を検査するため、別名へ変更しません。RSpec時の回復機能フラグはCIと同じ既定の無効状態にします（必要なテスト内で個別に有効化します）。

```sh
bin/dev-docker exec -e RAILS_ENV=test web bin/rails db:test:prepare
bin/dev-docker exec -e RAILS_ENV=test \
  -e DATABASE_URL=postgres://quickflow:quickflow-local-only@db/quickflow_test \
  -e QUICKFLOW_GRADING_RECOVERY_ENABLED=false \
  web bundle exec rspec --exclude-pattern 'spec/system/**/*'
bin/dev-docker exec web bin/rubocop
```

ブラウザを使うsystemテストはChromeが必要です。Macの分離テスト手順またはGitHub Actionsの全RSpecを使い、非system成功とは分けて報告します。RSpecでは実OpenAI client生成を禁止しています。

## GitHubからAWSへ

1. Macで編集・上記の開発確認・テスト。
2. 作業ブランチをpushしPRを作成。CIと差分を確認してmainへマージ。
3. 確定mainの追跡ファイルから**通常のDockerfile最終ステージ**で本番イメージを作り検証。開発targetを配備しない。
4. 稼働SHA、image ID、volume、バックアップ、切戻し方法を確認して既存配備手順でAWSへ反映。
5. 実稼働SHA、HTTPS、health、ログイン画面、Solid Queueを確認。
6. Macの未コミット変更を保護してmainを更新。Gem/Dockerfile変更時は開発webを再ビルド。

AWSは既存`compose.yaml`のproduction、固定イメージ、既存external volume、公開HTTPSを使います。開発ファイル共有・開発DB・開発HTTPは入りません。ゲスト版の更新や自動デプロイ新設は含みません。過去の切替証跡は[配備手順](issue51_predeployment_runbook.md)と[バックアップ・切替計画](aws_backup_cutover_plan.md)を参照してください。`git pull`だけでは稼働イメージは更新されません。
