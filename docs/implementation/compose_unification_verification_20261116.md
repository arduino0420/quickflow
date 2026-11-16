# Compose一本化：PR作成前のローカル検証記録（2026-11-16）

通常版は `compose.yaml` 1ファイルの `db`・`web`・`caddy` へ統一した。別Compose生成、重ね合わせ、同役割サービスのprofilesは使わない。旧開発Composeと旧entrypointは、共通構成のdevelopment/production起動確認後に削除した。ゲストサービスやDB schema・依存バージョンは変更していない。

## 反映と安全性

- Macの普段フォルダ `~/workspace/quickflow` から作業。開始時はcleanなmain `d84432eee2894d966df9a61d20052173fb790175`。Docker contextはdesktop-linux。
- 開発は `bin/dev-docker up --watch`。`Watch enabled` の表示後に編集し、保存・同期後にブラウザを再読み込みする。
- `up -d` だけでは同期しない。`watch --no-up` の終了は同期だけを止め、`up --watch` のCtrl+Cは起動したサービスも停止することを実確認した。
- Watch停止中の編集は再開時のinitial_syncで反映された。Controller・Model・View・JS・CSSを一時編集し、同じコンテナID・imageのまま実ブラウザの表示・DOM属性・CSS値を確認した。一時編集は復元済み。
- 新規Jobクラスは既存workerから認識されず、worker再起動が必要だった。既存Job/Serviceの変更は今回の試験では再読込されたが、手順では処理終了後の `restart web` を案内している。
- development imageへホストの古いcompiled assetを一時配置してbuildしたが混入せず、qpdfの実行ファイルはLinux ELFだった。MacのqpdfはMach-Oのまま保護した。
- 本番はproduction target・コードmountなし・read_only。image内のruntime markerと環境の不一致は実起動で拒否した。tmp/log/storageと/tmpの書込み、一時PDFとqpdfを確認した。
- 開発session secretはRailsがproject専用tmp volumeへ独立生成し、再起動で維持する。既存.envや本番credentialsは読み込まない。

## 検証結果

| 検証 | 結果 |
| --- | --- |
| 構成RSpec（Mac、最終development image内） | 各6件・失敗0 |
| RuboCop | 302ファイル・違反0。後続の設定・検査ファイルも再確認 |
| 関連RSpec：PDF/子プロセス/ログイン/提出/採点Job/教師確認/Excel | 初回252件中4件失敗、248件成功。/tmp tmpfsのnoexecが検証用子プロセス起動を妨げたためexec属性を指定。該当ファイル6件を再実行し失敗0 |
| 本番設定のHTTPS実HTTP | 20項目成功。架空アカウント/PDF、ログイン、配布、表示、下書き、提出、Excel、実workerのAPIキー不足処理 |
| 模擬結果から教師確認・得点・Excel | 5項目成功。模擬needs_reviewを残して教師correctを優先し5点を出力。実AIではない |
| 停止・再開のDB/PDF保持 | developmentとproduction設定の専用環境で、cluster識別・primaryの全19表件数・storage全ファイルhashが前後一致 |
| Compose構文・CI YAML・シェル構文・差分空白 | 成功 |
| 実AI / AWS変更 / GitHub CI | このPR前ローカル記録の時点では未実施。配備結果は最終作業報告で別に確認する |

初回の検証用手順には、Watch準備完了前の新規ファイル作成、教師パスワードの既存規則、Excelのclassroom_id指定の不足があった。アプリ規則を変えず、検証手順を修正して確認した。テスト用AI結果の直接fixtureと実AI応答は区別している。

開始時にDocker DesktopのVMが起動直後にクラッシュした。ログでVM停止を確認して管理プロセスを終了し、通常起動で復旧した。Docker disk、volume、DB、PDFは削除していない。検証用networkの自動subnet枯渇は、既存networkを削除せず、重複のない検証専用/28 subnetを明示して回避した。

証跡は実行環境の `/tmp/qf-compose-20261116/` の個別result/logに保存した。同じ領域の検証用.envなどは秘密として扱い、ディレクトリ全体を共有しない。

普段の操作・再起動/再作成/build/migration・AWS手順は[ローカルDockerワークフロー](local_docker_workflow.md)を参照。
