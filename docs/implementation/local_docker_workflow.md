# Dockerによるローカル開発と本番相当確認

目的は、**Macで編集 → Dockerで検証 → PRとCI → 承認後mainへ統合 → 別途承認してAWSへ配備**という流れを再現可能にすることです。この設定はローカル専用であり、AWSのCompose置換や自動デプロイではありません。

最新mainを基準に整備します。古い本番コードをmainへ上書きせず、普段の作業フォルダ・未コミット変更・既存DBを保護した独立checkoutで先に検証してください。PRの公開・マージ、普段のフォルダへの同期、AWS変更はそれぞれ結果を見て判断します。

## 3つの用途を混ぜない

| モード | 構成 | 用途と意図的な差 |
|---|---|---|
| `dev` / `compose.yaml` | Caddy → Puma/Rails development → 専用PostgreSQL | コード再読込・詳しいエラー表示。既存developmentのasyncジョブを維持し、Thrustは使わない |
| `check` / `compose.check.yaml` | HTTPS Caddy → Thrust → Puma/Rails production＋Solid Queue → 専用PostgreSQL | 本番用イメージのアセット・起動・永続ジョブ・PDF・認証を確認 |
| `test` / `compose.test.yaml` | 試験専用イメージ＋別のPostgreSQLクラスタ | RSpec・JavaScript・system試験。試験ツールを本番イメージへ追加しない |

入口はdevが `http://localhost:18080`、checkが `https://localhost:18444` です。testはホストへポートを公開しません。

DB、保存volume、network、project、公開ポートを分離します。テストDBは既存specの安全ガードが要求する `quickflow_test` ですが、**この名前はtest用Dockerクラスタの内部だけ**です。Macの既存PostgreSQLやdevelopment/checkのDBへ接続しません。

日々の開発で画面が動いただけでは、Solid Queueによる本番の採点連携まで確認したことになりません。`check`でも確認してください。

## 前提と安全境界

- Docker DesktopとDocker Compose、Python 3を利用します。Docker接続先はローカルUnix socketだけを受け入れ、remote SSH/TCP接続を拒否します。
- 操作は `bin/local` を入口にします。Composeファイル、project名、envファイルを固定し、他の作業のDocker/Compose環境変数を無条件に継承しません。
- 本番のmaster key、APIキー、DB/PDF、バックアップをコピーしません。ローカル用secretは新規生成し、Git・build context・CI artifactへ含めません。
- 本番キーを含み得るrepo全体やconfig全体をbind mountしません。必要なソース・設定だけを読み取り専用で反映し、tmp/log/storageは専用volumeに分けます。
- アプリ/DBは内部network、Caddyだけ入口networkにも接続します。公開はlocalhostに限定し、DBポートは公開しません。
- `dev`/`check`は架空AI応答が初期値です。実AIキーを渡したり、実生徒情報を投入したりしません。架空AIや検証用mountが配備イメージへ混入しないことを確認します。
- OSへローカルCAを勝手に信頼登録しません。ローカルTLSの検証方法は専用クライアントの範囲に限定します。

## 操作の順番

リポジトリのルートで実行します。ポートや接続先の衝突時は、既存サービスを止めて解消するのではなく、理由を確認してください。

```sh
# 開発環境: image作成 → 専用DB初期準備 → 起動
bin/local dev build
bin/local dev init
bin/local dev up
bin/local dev verify
bin/local dev smoke
bin/local dev status

# 作業後はこのモードだけ停止。DB/PDFは保持
bin/local dev stop
```

`init`は新規専用DBの準備と対象確認です。既存DBをreset/dropするコマンドではありません。`up`は準備済みのDBで起動するだけで、意図せず `db:prepare` を実行しません。既存volumeの由来やschemaが不明なら処理を進めません。

再開は `bin/local dev up`、停止は `bin/local dev stop` です。DB/PDFの永続化を確認してから日常的に使います。マイグレーションが追加された場合は、対象と変更内容を確認して別途適用します。

### コード編集はどう反映されるか

- Mac側で編集した、mount対象の `app` / `lib` / 設定ファイルをコンテナが読み取ります。Rails developmentの再読込により反映します。
- コンテナ側は読み取り専用なので、ホストのコードを勝手に書き換えません。generatorや `credentials:edit` のようなファイル作成をコンテナ内で実行する手順ではありません。
- devの主なmount対象は `app` / `lib` / `db` / `public` / `spec` と安全な設定ファイルです。initializerも既存の許可対象だけをmountし、新しいinitializerはallowlistの見直しが必要です。
- mount対象外の追加設定ファイルは、自動で反映されるとは限りません。対象一覧を確認し、設定変更・起動し直し・再buildのどれが必要か判断します。
- Gemfile/Gemfile.lock、Ruby、OS依存、Dockerfileを変更したら再buildが必要です。現在のlockとimage内bundleがずれた状態を起動検査で拒否します。
- `check`はソースをimageへ取り込むため、Macの編集は既存コンテナへ自動反映しません。変更後はbuildし直し、その新imageを検証します。

## 本番相当の確認

```sh
bin/local check build
bin/local check init
bin/local check up
bin/local check verify
bin/local check smoke
bin/local check stop
```

`check`は通常版の処理構成を対象とします。guestの専用DB・読み取り専用制限・共有Caddyを含む本番全体を置き換えるものではありません。

`dev smoke` は開発環境の実HTTP経路だけを検証します。developmentではリクエスト文脈が異なるため、ActionDispatchのHTTPS模擬試験を代用しません。`check smoke` はアプリ内統合19項目と実HTTPS17項目を別々に実施します。これらはブラウザでの手書き操作の証明ではありません。

試験結果では次を区別します。

1. **アプリ内統合**: ActionDispatchによるHTTPS模擬・CSRF・アプリ処理と実workerの連携。
2. **実HTTP/HTTPS**: localhostからCaddy/Thrust/Pumaを経由したログイン、PDF、提出、採点待ち、教師修正、Excelなど。
3. **実ブラウザ**: JavaScript、手書きCanvas、下書き保存、PDF生成、遷移・再提出など。
4. **実AI**: 今回は実施しません。架空応答での成功は精度・レート制限・課金・外部障害の検証ではありません。

`/up`の200だけで全機能成功とは判断しません。外部通信についても、internal network構成の検査と特定宛先への通信拒否試験を区別します。

### Mac Chromeで手書き操作を再確認する

`dev`を準備済みのMacで、リポジトリのルートから実行します。`smoke`はブラウザ試験が使う架空データのprivate fixtureも準備します。

```sh
bin/local dev up
bin/local dev smoke
rbenv exec ruby docker/local/browser-smoke.rb
bin/local dev stop
```

既存のMac版Google Chrome、rbenv側のRubyから使える `selenium-webdriver 4.52.0`、対応するキャッシュ済みChromeDriverが前提です。driverがなければ失敗して止まり、勝手にダウンロードしません。現在のスクリプトは `~/.cache/selenium/chromedriver/mac-x64` の対応major versionを探します。別CPU/driver配置では前提を確認してください。

毎回新しいprofileを作り、普段のChrome profileを使いません。sandboxは有効のままです。証跡は `.local/dev/browser-<識別子>/` に分離されます。実AIは使いません。これはdevの実ブラウザ試験であり、checkの実ブラウザ試験やfull system RSpecの代替ではありません。

## 自動テストとCI

```sh
bin/local test build
bin/local test init
bin/local test test
bin/local test stop
```

Linux Chromiumを標準sandboxで起動できない場合は、`bin/local test test-core` による非system試験とMac Chromeでの実ブラウザ検証を別々に記録します。`test-core` の成功はfull RSpec成功ではありません。Mac Chromeの検証結果も、実行が終わるまで未確認です。

test用イメージだけにNode、プロセス検査、ブラウザ/driverなど必要な試験ツールを持たせます。本番相当のアプリ/Gemを勝手に変更しません。ブラウザ試験が実行できなければ、非ブラウザ試験の成功で代替せず未実施として報告します。OSのセキュリティ設定を弱めて通すことはしません。

既存CIの監査・lint・RSpecを維持し、PostgreSQLイメージを固定します。追加の `docker_check` は本番用imageをbuildし、**その同じimage**で専用DB・保存先を使った実HTTP smokeを実施します。本番secret、APIキー、registryへのpush、AWS配備はありません。失敗時はCIログにallowlistされたimage/lock識別情報・隔離検査結果と、構造化されたcheck名/成否だけを表示します。Railsログ全文・fixture・秘密値をartifactに公開しません。

証跡はモードごとの `.local/<mode>/evidence/` に残します。共有時は検証結果・runtime識別情報だけを選び、`runtime.env`、secret、`*.private.json`などは含めません。実際に実行したcommit/image ID、件数、失敗・未実施項目を報告し、過去の成功を現在の成功と混同しません。

## 本番との比較と、配備判断

揃える対象は、コード、Gemfile.lock、Ruby、PostgreSQL/Caddy image digest、Thrust/Puma/Solid Queue、PDF処理、DB/PDFの永続化です。Rails developmentの再読込、async、エラー表示は本番と意図的に違います。localhostのTLS、架空データ、secret、MacのCPU/メモリ、EBS、実AIは本番と同一ではありません。

最新mainには現在の本番より新しいRails/OpenAIなどの依存があります。同じアプリコードでもAPI・依存の差があるため、最新lockで再検証します。必要なら実SDKとローカル模擬HTTPで形式互換を確認しますが、それでも実AI動作の保証ではありません。

次の順番を守ります。

1. 独立checkoutで整備・検証し、結果と残る差を報告。
2. 承認後にPRを作成し、CI・レビュー。
3. 承認後にmainへ統合し、普段のquickflowの未コミット変更・DB・保存先を再確認して同期。
4. 普段のフォルダでも起動・編集反映・停止・再起動を確認。
5. [AWS Compose移行計画](aws_compose_migration_plan.md)を現在の稼働状態に合わせ、実配備の直前に別途承認。

問題があれば次の段階へ進みません。既存のネイティブ開発環境は確認が終わるまで残し、古い本番コードを最新mainへ上書きしません。

## 本番確認用Composeの実ブラウザ手書き試験

通常のdev試験と別に、checkのproduction assets・Solid Queue・実HTTPS経路でも確認できます。Macの既存Chrome、Selenium 4.52.0と対応するキャッシュ済みdriverを使います。

自己署名証明書の例外は、事前に利用者が許可した場合だけ使用します。`certificate-proof.rb`が`bin/local check verify`を実行し、専用Caddyの識別・image・volume・loopbackポートを確認したうえで、公開証明書と実TLSのDER指紋・SAN・期限を照合します。秘密鍵は読みません。

```sh
bin/local check up
bin/local check smoke
rbenv exec ruby docker/local/certificate-proof.rb
# 次は承認済みの検証セッションでのみ実行する
QF_LOCAL_PINNED_CERT_OPT_IN=1 \
QF_LOCAL_CERT_SPKI="$(rbenv exec ruby -rjson -e 'puts JSON.parse(File.read(".local/check/browser-certificate-proof.json")).fetch("spki_sha256_base64")')" \
rbenv exec ruby docker/local/browser-smoke.rb check
bin/local check stop
```

ブラウザは10分以内のproof、同一Caddy、実証明書を再照合します。新規専用Chromeプロファイル内でその公開鍵だけに例外を限定し、`accept_insecure_certs=false`を維持します。SPKI例外は証明書の公開鍵単位なので、厳密なleaf証明書限定ではありません。このため起動直前のleaf指紋一致も必須にしています。通常Chrome・OS信頼ストア・sandboxは変更しません。画面・リンク・フォームは固定localhost起点を確認します。proof、profile、実行ログは`.local/`内だけに保持し、コミットしません。
