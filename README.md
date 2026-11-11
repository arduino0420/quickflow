# QuickFlow

[公開アプリ](https://13-231-93-159.sslip.io/) · [閲覧専用ゲスト](https://qfd-4c18332acca47671.13-231-93-159.sslip.io/)

## プロジェクト概要

中学校数学の小テストを、PDF教材の配信から手書き解答・採点・成績出力まで支援するRailsアプリです。教師の採点や転記の負担を減らし、生徒へ結果を返すまでの時間を短くすることを目指しています。

AIは採点を補助し、教師が保存した判定を優先します。読みにくい答案などは「要確認」とし、教師が確認するまで得点に加算しません。

## 使用技術

| 分野 | 技術 |
| --- | --- |
| 言語・フレームワーク | Ruby 4.0.6 / Ruby on Rails 8.1.4.1 |
| データベース・非同期処理 | PostgreSQL 18.6 / Solid Queue |
| フロントエンド | Hotwire（Turbo・Stimulus）/ Importmap |
| PDF・成績出力 | Active Storage / PDF.js / pdf-lib / qpdf / caxlsx |
| AI連携 | OpenAI API（読み取り・正答生成・採点補助） |
| 開発・配備 | Docker / Caddy / AWS EC2 |
| テスト・CI | RSpec Rails 8.1.0 / GitHub Actions |

バージョンの詳細は [.ruby-version](.ruby-version)、[Gemfile.lock](Gemfile.lock)、[compose.yaml](compose.yaml) を参照してください。

## 主な機能

- **教師**：担当クラスの生徒登録、PDF教材の配信、答案・AI判定の確認と修正、得点集計、クラス別のExcel出力。
- **生徒**：PDFへの手書き、下書きの自動保存・復元、答案の正式提出、採点結果の確認。
- **管理者**：自校の教師・生徒の登録や所属管理、生徒のパスワード再設定・条件を満たす削除。
- 学校・担当クラス・配信先・作成者に応じたアクセス制限。

## 使い方

1. 登録済みのアカウントでログインします。入口は教師 `/login`、生徒 `/student/login`、管理者 `/admin/login` です。公開サインアップはありません。
2. 教師がPDF教材・1問の点数・配信先クラスを指定して小テストを配信し、正答生成の状態を確認します。
3. 生徒がPDFに手書きし、保存状態を確認して「提出する」を押します。答案PDFのアップロードも利用できます。
4. 教師が答案とAI判定を見比べ、必要に応じて判定を修正します。
5. 生徒が結果を確認し、教師が成績一覧やExcel出力を利用します。

**自動保存だけでは正式提出されません。提出後の答案の差し替えはできません。** 未保存のまま画面を閉じず、提出・採点に問題がある場合は教師へ確認してください。

画面を試す場合は、公開トップの「ゲストとしてログインする」から役割を選びます。ゲストは架空データの閲覧専用で、登録・編集・手書き・提出・実AI採点はできません。実生徒の情報を入力しないでください。

[画面付きの操作説明](docs/implementation/readme_details.md#使い方と画面) / [登録方法・利用上の注意](docs/implementation/operations_details.md)

## セットアップ手順

Macでの基本手順です。Git、Docker Desktop（Docker Compose）、初回設定用のRuby・Python 3を用意し、既存の環境とは別の新しいフォルダを使います。

1. リポジトリを取得します。

   ```bash
   git clone https://github.com/arduino0420/quickflow.git quickflow-local
   cd quickflow-local
   ```

2. [初回のMac準備](docs/implementation/local_docker_workflow.md#初回のmac準備)に従い、`.env`、専用のDB・PDF保存領域、ネットワーク、新規DBのスキーマを準備します。既存の設定やデータを上書きせず、本番の鍵・実生徒データを持ち込まないでください。

3. 初回準備の完了後、アプリを起動します。コードを編集したときも再ビルドします。

   ```bash
   docker --context desktop-linux compose build web
   docker --context desktop-linux compose up -d --wait --wait-timeout 120
   ```

4. `https://localhost:18443` を開きます。ポートを変更した場合は `.env` の設定に合わせてください。ローカル証明書の信頼方法は[HTTPSの注意事項](docs/implementation/local_docker_workflow.md#aihttps本番との差)を確認します。

終了時は `docker --context desktop-linux compose stop` で停止します。DB・PDFは残ります。

**ここまでの手順は起動確認までです。** 新規DBは空なので、ログインして使うには運用担当者が同じDocker内のDBへ学校を用意し、初期管理者・利用者を登録する必要があります。[アカウント運用の詳細](docs/implementation/operations_details.md#アカウント登録mvp)にある登録タスクも、学校が存在することが前提です。実AIには別途APIキー設定と利用料金が必要です。

[Dockerを使わない起動・隔離したRSpecの手順](docs/implementation/readme_details.md#ローカル起動とテスト)も用意しています。テストは専用DB・保存先で実行し、既存DBの `drop` / `reset` は行わないでください。

## ディレクトリ構成

```text
quickflow/
├── app/
│   ├── controllers/   # 教師・生徒・管理者のリクエスト処理
│   ├── models/        # データの関連・検証
│   ├── views/         # 画面テンプレート
│   ├── javascript/    # PDF表示・手書き・自動保存
│   ├── services/      # AI連携・採点・成績出力など
│   └── jobs/          # 正答生成・答案読み取り・採点の非同期処理
├── config/            # ルーティング・DB・環境設定
├── db/                # マイグレーション・スキーマ
├── spec/              # RSpecテスト
├── docs/              # 設計・操作・運用・検証資料
├── docker/            # Caddyの設定
├── bin/               # 起動・検査用コマンド
├── Dockerfile         # アプリのコンテナ定義
└── compose.yaml       # DB・アプリ・Caddyの構成
```

[設計・構成図](docs/design/README.md) / [詳しい説明・検証記録](docs/implementation/readme_details.md) / [提出要件の対応表](docs/implementation/issue103_submission_evidence.md)
