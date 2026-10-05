# QuickFlow学習サイトの運用

## 自動更新の対象
QuickFlowについてexplainerを使った解説依頼では、解説をチャットだけで終えず、記事原稿・メタ情報・記事一覧・HTMLの作成または更新と検証まで行う。READ/PLANのみ、ファイル変更禁止などの明示的指示がある場合は書き込まない。

## 毎回の手順
1. explainerのSKILL.mdとpersonas/owner.mdを読む。既存記事のmetadata.jsonを確認し、同じテーマのIDを再利用する。
2. QuickFlowの実際のコードを読む。説明の原稿をarticles/<id>/README.mdに保存する。初心者向けに意味を先に説明し、コード・表・流れ・理解度チェックを含める。
3. metadata.jsonのタイトル、要約、Issue、更新日、対象コミット、dirty状態、sourceFilesを更新する。対象コードの現在のSHA-256をchecks.jsonのsourceHashesへ記録する。コードの抜粋はchecks.jsonのsnippetsで実ファイルと照合する。ファイルハッシュの一致だけを動作検証済みと呼ばない。
4. 必要な振る舞いのテストを実行し、結果・実行日・未検証事項をverificationへ記録する。過去の結果を今回の実行結果として書かない。
5. 学習サイト内でnpm run build、npm run verify、npm testを実行する。図やHTMLにexplainerのverify-doc.mjs等を利用する場合、依存解決のためdocs/learningを作業ディレクトリにする。未実施の検証をVERIFIEDと報告しない。
6. Browserスキルで一覧から記事への移動と表示を確認する。検証できない点は記事と報告で明示する。
7. チャットで解説の要約、サイトへのリンク、変更ファイル、検証結果を返す。

## 保存ルール
- 記事IDは小文字英数字とハイフンのみ。今回の登録機能はissue-11-assignment-creation。日付だけで別記事にしない。
- Markdownが原本、distは生成物。distを直接修正しない。記事とdistはGit管理し、node_modules・一時ファイルは除外する。
- 学習者情報はこの学習サイトのpersonas/owner.mdに保存する（explainer標準のルートpersonas配置へのプロジェクト固有の上書き）。事実と仮定を区別する。
- 必要な依存はこのディレクトリ内だけに追加する。app/、config/、db/、Gemfile、既存CIを変更しない。公開、commit、pushは別の明示的指示が必要。
- 原稿や既存記事を無断で削除しない。既存assignment_explainer.htmlも維持する。
- 新しい記事は既存metadata.jsonの構造を参考にする。verificationはstatus・summary・limitations、checks.jsonはsourceHashes・snippetsを持つ。buildは記事を追加し、同じIDなら同じHTMLを更新する。

## 検証の範囲
npm run verifyは入力構造、コードのハッシュと抜粋、生成物の一致、リンク、外部依存・スクリプトの不在を検査する。Railsの振る舞いやブラウザでの見た目は別の検証であり、この検査だけで保証しない。
