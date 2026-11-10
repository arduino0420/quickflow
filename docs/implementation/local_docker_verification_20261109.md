> 履歴資料: この記録はPR #203の旧dev/check/test構成です。現在の起動手順には使用しないでください。現行の[単一Compose手順](local_docker_workflow.md)と[新構成の検証記録](single_compose_verification_20261109.md)を参照してください。以下の旧ファイル名・コマンド・件数は当時の記録として残しています。

# ローカルDocker整備 第2段階の検証記録（2026-11-09）

## 結論と変更範囲

最新mainを起点にした独立作業フォルダで、開発用・本番相当確認用・テスト用Composeと安全な操作入口を整備しました。devの実HTTP、checkのアプリ内統合と実HTTPS、Mac Chromeの手書き操作、編集反映、停止・再起動後の保存維持を確認しました。**AWSへそのまま配備してよいという結論ではありません。**

作業場所は `quickflow-production-check/main-compose-development` です。普段のquickflow、先行検証用app、GitHub main、AWS本番は変更対象ではありません。本番データ・本番鍵を持ち込まず、架空データ・ローカル専用secret・模擬AIで検証しています。PR作成・マージ・普段のフォルダへの統合・本番変更は未実施です。

## コードとイメージの識別

- 基準main: `a3acc0f6b1e03658a069d0d136037d5693829be7`
- 比較対象の通常版本番コード基準: `c2e1d529`。本番には依存更新の重ね適用があり、コード基準と稼働Gemを別々に比較します。
- 上記基準間のアプリコードには変更がありませんが、Gem更新があります。古い本番コードへ巻き戻す方法は採っていません。
- checkのbuildとsmokeが記録した同一image ID:
  `sha256:791547dc866306a83ee94e12296c0e0a957518791a96ad9734c34c7ed569c50e`
- checkのsource fingerprint: `0a199446a93b4be012e21eaa6feb9c26466c88ae785e0feba0e674c95e2d8522`
- checkのGemfile.lock fingerprint: `cc157879453690700dfc84722a5f1068af7fc1cb4289aa88982c0009045fab1c`

証拠は `.local/check/evidence/build.json` と `smoke.json` です。source fingerprintはwrapperが計算する識別値であり、Git commit IDではありません。作業変更は未コミットなので、将来のPR/配備候補はその時点のcommitとimageで再検証します。

## 実施結果

| 検証 | 結果 | 証跡・確認できる範囲 |
|---|---|---|
| dev実HTTP | PASS | `.local/dev/evidence/http-smoke.log` / `smoke.json`。Caddy→Puma/Rails development。Thrustを経由しない |
| checkアプリ内統合 | 19項目 PASS | `.local/check/evidence/inprocess.log`。ActionDispatchのHTTPS模擬・CSRF・実worker連携。ネットワーク経路の証明とは別 |
| check実HTTPS | 17項目 PASS | `.local/check/evidence/http-smoke.log`。fixture準備成功1件とは別の17チェック。Caddy→Thrust→Puma、ログイン・PDF・提出・採点待ち・教師修正・Excel・生徒結果 |
| 実ブラウザ | 10項目 PASS | `.local/evidence/browser-smoke.log`。Mac Chrome、新しいprofile、sandbox有効。devのブラウザ操作でありcheckの実ブラウザ試験ではない |
| 編集反映 | PASS | `.local/dev/evidence/hotreload.json`。Rubyソース編集が再buildなしで反映し、元へ戻した応答も確認 |
| 停止→再起動・再init | dev/check PASS | 各 `restart.json`。架空データ件数とstorage hashが前後一致、再initでデータを初期化しない |
| 操作入口の安全ガード | 19件 PASS | `.local/evidence/guard-tests.log` |
| 内部network・入口分離 | PASS | dev/checkの `isolation.json`。専用projectと必要serviceを検査 |
| 外向き通信の試験 | 試験先への接続拒否 | 各 `egress.json`。`1.1.1.1:443` が `ENETUNREACH`。全宛先を網羅して試したという意味ではない |
| 非system RSpec（test-core） | 2,125件・失敗0 | `.local/test/evidence/rspec-core.log` / `rspec-core.json`。専用test DB、system specを明示除外。実行時間7分46秒 |
| full system RSpec | 未実行 | 事前確認でLinux Chromiumの標準sandboxがnamespace権限で起動できず、suiteは開始していない。sandbox無効化などの回避はしていない |
| RuboCop | 305ファイル、違反なし | 最終整形後の全体検査（実行担当からの確認結果） |
| GitHub Actions | 未実行 | workflow整備・YAML解析・診断コード確認まで。PR/pushしていない |
| 実AI通信 | 未実施 | 今回の対象外。APIキー未使用 |

### 実ブラウザで確認した操作

教師ログイン、PDF配布、生徒ログイン、PDF.js描画、実際のポインタ操作による手書き、下書き保存、再読込後の復元、提出キャンセル後の筆跡保持、手書きPDFの正式提出、教師の確認・修正とExcel出力を確認しました。最終整形後にも再実行し、証跡ディレクトリ `.local/dev/browser-0d5902915185` でPASSしました。採点応答は模擬です。これを全ブラウザ・全端末・全system specの成功と読み替えません。

### 保存維持の具体的な結果

checkは学校3件・提出4件・blob8件、devは学校2件・提出2件・blob6件が再起動の前後で一致しました。storage全体の検査hashも前後一致しています。これは試験時点の架空データについての結果で、本番EBSの障害復旧・バックアップ復元試験ではありません。

最終確認後、dev/check/testを停止しました。専用DB/PDFのvolumeは保持しています。

## 本番との一致点・意図的な相違・未確認

| 項目 | 今回の状態 | AWSへ反映する際の意味 |
|---|---|---|
| Railsアプリコード | main基準。比較対象の本番コード基準からappコード変更なし | 最新機能を古いコードで上書きしない。次の候補commitでも差分確認が必要 |
| Ruby | check実測 `4.0.6` | `.local/check/evidence/versions.json`。Ruby/Gem/OS/CPUを一括して同一とはしない |
| Rails/Gem | Rails `8.1.4.1`、OpenAI `0.115.0`、bootsnap `1.26.1`、msgpack `1.8.7` | 最新mainのlock。現在本番の古い依存とは差があるため、今回の検証だけで実AI API互換まで保証しない |
| Puma/Thrust/Solid Queue | check実測 `8.0.2` / `0.1.27` / `1.7.0` | checkはproduction＋永続worker。devはdevelopment/asyncでThrustなし |
| PostgreSQL | `18.6` のdigest固定 | 各用途で独立DBクラスタ・volume。本番DBを複製していない |
| Caddy | image digest固定。checkでローカルHTTPS | 本番ドメイン・公開証明書・DNS・Security Groupを再現していない |
| コンテナ管理 | dev/check/testを独立Compose管理 | 現在AWSのアプリはCompose管理外。ローカルComposeをAWSへ上書きするだけでは移行できない |
| 採点 | dev async、check Solid Queue。架空応答で保存・教師修正・出力を確認 | 実AIの精度、通信形式、レート制限、障害・費用は未検証 |
| 保存 | DB/PDFを専用Docker volumeへ永続化 | Mac Docker Desktop上の保存でありEBSそのものではない。バックアップ・復元・容量設計は別検証 |
| ゲスト版 | 対象外 | ゲスト専用DB、制限、共有Caddyとの共存を次のAWS計画で確認 |
| 性能・運用 | 単独の架空操作フロー | 30人同時提出、AWS性能、長時間稼働、障害復旧を今回の成功から保証しない |

依存イメージの固定値:

- PostgreSQL: `postgres:18.6@sha256:74935e72241653ca55e0414067e6d8763aceb8a810eb51b452253ec3dcfc4336`
- Caddy: `sha256:685ae3d7c34d9b5f8caeddc5d14051db7bbd88ff1f5a2fa0c16bd8ca328fb7af`

## 作成・変更したもの

- `compose.yaml` / `compose.check.yaml` / `compose.test.yaml`: dev/check/test分離。
- `Dockerfile.dev` / `Dockerfile.test`: 開発・試験用依存。本番イメージへ試験ツールを追加しない。
- `bin/local`: local Docker限定、明示的なbuild/init/up/stop/verify/smoke/test入口。
- `docker/local/`: Caddy設定、模擬AI、架空fixture、統合/HTTP/ブラウザsmoke、安全ガード試験。
- `.dockerignore` / `.gitignore`: 秘密情報・ローカル状態・証跡の混入防止。
- `.github/workflows/ci.yml`: 既存監査/lint/RSpec維持、PostgreSQL固定、同一imageの隔離HTTP確認、失敗時の限定診断。
- `README.md`、[ローカル手順](local_docker_workflow.md)、[将来のAWS移行計画](aws_compose_migration_plan.md)、本記録。

証跡は `.local/` に保存していますが、フォルダ全体を共有しないでください。runtime.env、秘密値、private fixtureなどを除き、結果・識別情報だけを選びます。

## 残る作業と次の判断

1. test-coreは2,125件・失敗0。full systemと実際のGitHub CIは次段階の未確認事項として残す。
2. 最終差分と独立レビュー、再現手順・制限を確認してユーザーへ報告する。
3. **別途承認後**にPRを作成し、実際のGitHub CIを確認する。まだ実行していないCIを成功扱いにしない。
4. レビューと承認後にmainへ統合し、普段のquickflowの未コミット変更・DB・保存先を再確認して安全に同期する。
5. 普段のフォルダで起動・編集反映・停止・再起動を再確認する。
6. AWSの実稼働状態を取り直し、通常版/ゲスト版/共有Caddy、volume、job停止、migration、backup/restore、schema互換rollbackを具体化する。本番変更はその直前に改めて承認を得る。

手順は[ローカルDockerワークフロー](local_docker_workflow.md)、本番への移行条件は[AWS Compose移行計画](aws_compose_migration_plan.md)を参照してください。

### 最終確認

- RSpecには実OpenAI SDK＋模擬HTTP transportの25件を含む。実AIサービスへの通信ではない。
- Brakeman 8.1.0: エラー0、セキュリティ警告0。
- RuboCop: 305ファイル、違反0。
- 最終確認時点のGitHub mainも `a3acc0f6b1e03658a069d0d136037d5693829be7`。
- アプリ本体・Gemfile/lock・本番Dockerfileは基準mainから変更なし。普段のquickflowと先行app checkoutも未変更。
- 独立レビューで指摘された古いイメージ誤検証・停止中環境の誤PASSを修正し、追加の重大な問題は見つからなかった。
- dev/check/testの今回専用コンテナは検証後に停止。DB・保存volume・image・証跡は保持。再開は手順書に従う。

## PR段階の追記（2026-11-09）

上記は第2段階終了時点の記録です。その後の承認で、専用ブランチから確認用draft [PR #203](https://github.com/arduino0420/quickflow/pull/203)を作成しました。mainへのマージ・普段のquickflowへの統合・AWS変更は行っていません。

- 初回commit `72ad76a4a20b372ff782a06d30076c4506b1f2fd` の[CI run 42593621078](https://github.com/arduino0420/quickflow/actions/runs/42593621078)は全5ジョブ成功。
- GitHub runnerでsystem除外なしの全RSpecを実行し、**2,263件・失敗0**（10分33秒）。ローカルDockerのChromium制約を安全設定の緩和で回避したものではありません。
- 通常版check Composeの実ブラウザでも手書き・下書き・再読込・取消・正式提出・模擬採点・教師修正・Excelの10項目が成功。
- このブラウザ試験では、条件付き承認のもと専用Caddyの公開証明書と実TLSの一致を確認し、専用ChromeだけにSPKI限定例外を使用。全面的な証明書検証無効化、OS変更、sandbox解除はなし。
- 再現用の証明書proof生成helper、10分期限・Caddy再照合・localhost起点制限を追加。許可なし／違うpinの2条件ではChrome起動前に拒否することを確認。
- 本追記とブラウザ強化は後続コミットに含まれるため、初回CI成功だけで最終head成功とは判断しない。**マージ判断ではPRの最新headのCI結果を必ず確認する。**

実AI・EBS・ゲスト版・負荷・復旧などの未確認事項は引き続き残ります。mainへのマージとAWS配備には別途判断が必要です。

### 追加監査指摘への修正

中間head `be6aded` のCIでは、証明書preflightの検証無効化がBrakemanに検出されました。警告のignore/suppressは追加せず、専用Caddyの公開CAだけを一時OpenSSLストアへ登録し、`VERIFY_PEER`・証明書チェーン・localhost名検証を行う方式へ修正しました。OSの信頼設定や通常Chromeは変更していません。修正後のローカルBrakemanはエラー0・警告0で、最終headのCIはPR上で別途確認します。
