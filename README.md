# QuickFlow

[公開アプリ](https://13-231-93-159.sslip.io/)　[紹介動画](https://youtu.be/QXBPQ1iQGF4)

## プロジェクト概要

QuickFlowは、AIによる自動採点を搭載した学習支援Webアプリケーションです。中学校の数学の小テストを題材に開発しました。
教師は普段使っている問題プリントを配信して、生徒はQuickFlowの中で直接解答を書いて提出、AIが自動で採点した結果を確認します。最後に先生が採点結果を、Excel形式で出力させることもできます。

AIは採点を補助し、読みにくい答案などは「要確認」にします。教師が保存した判定を優先して成績として反映する設計になっています。

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

![QuickFlow構成図](docs/images/quickflow-architecture.png)

## 主な機能

- **教師**：PDF教材の配信、AI判定の確認と修正、Excel形式の成績出力。
- **生徒**：解答の手書き、下書きの自動保存・復元、答案の正式提出、採点結果の確認。
- **管理者**：自校の教師・生徒の登録や所属管理、生徒のパスワード再設定。
- 学校・担当クラス・配信先・作成者に応じたアクセス制限。

## 使い方

1. 登録済みのアカウントでログインします。入口は教師 `/login`、生徒 `/student/login`、管理者 `/admin/login` です。公開サインアップはありません。
2. 教師が教材・1問の点数・配信先クラスを指定して小テストを配信します。
3. 生徒が画面に対して直接解答を手書きし、「提出する」を押します。AIによる採点が完了したら、結果を確認します。
4. 教師が答案とAI判定を見比べ、必要に応じて判定を修正し、成績をExcel形式で出力します

## セットアップ手順

Mac向けの手順です。初めて使うときは、1〜3の順に進めます。

### 用意するもの

- Git（アプリをダウンロードする道具）
- Docker Desktop（アプリを動かす道具。先に起動しておきます）
- Ruby・Python 3（初回の準備で使います）

### 1. アプリをダウンロードする

Macのターミナルで実行します。保存先は新しいフォルダにします。

```bash
git clone https://github.com/arduino0420/quickflow.git quickflow-local
cd quickflow-local
```

### 2. 初回の準備をする

リンク先の[「初回のMac準備」](docs/implementation/local_docker_workflow.md#初回のmac準備)の項目を順に実行します。**設定と専用のデータ保存場所を作り、アプリを起動**します。この準備は初回だけです。

既存の設定・データは上書きせず、本番用の鍵や実際の生徒データは使わないでください。

### 3. ブラウザで開く

[https://localhost:18443](https://localhost:18443) を開きます。接続ポートを変えた場合は、`.env` の `QF_HTTPS_BIND` の末尾にある番号を使います。

証明書の警告が出たら、[HTTPSの注意事項](docs/implementation/local_docker_workflow.md#aihttps本番との差)を確認してください。

### 次回からの起動・停止

`quickflow-local` フォルダ内で実行します。

**起動・再開**

```bash
docker --context desktop-linux compose up -d --wait --wait-timeout 120
```

**停止**（データやPDFは残ります）

```bash
docker --context desktop-linux compose stop
```

**コードを編集したとき**は、起動前に変更を反映します。

```bash
docker --context desktop-linux compose build web
```

### 使い始める前に

- **ログイン**：新しいDB（データ保存場所）は空です。運用担当者が同じDocker内のDBに学校を用意し、[初期管理者・利用者を登録](docs/implementation/operations_details.md#アカウント登録mvp)してから使います。
- **AI採点**：別途APIキーの設定と利用料金が必要です。
- **テスト・Dockerを使わない起動**：[詳しい手順](docs/implementation/readme_details.md#ローカル起動とテスト)を参照してください。テストは専用DB・保存先で行い、既存DBの削除・初期化（`drop` / `reset`）はしないでください。

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
