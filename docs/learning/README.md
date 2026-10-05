# QuickFlow学習サイト

QuickFlowのコード解説を蓄積するローカルの静的サイトです。Railsサーバー・DBは不要です。

## 開く
リポジトリルートで `open docs/learning/dist/index.html` を実行するか、dist/index.htmlをブラウザにドラッグしてください。

## 再生成と検証
```sh
cd docs/learning
npm ci
npm run build
npm run verify
npm test
```

原稿はarticles/<記事ID>/README.md、記事情報はmetadata.json、コード照合情報はchecks.jsonです。生成されたdistもGit管理します。検証状態・対象コミット・未検証事項は各記事に表示します。

explainerの利用時はAGENTS.mdの指示によりエージェントが記事作成・更新と上記処理を実行します。バックグラウンド監視やスキル呼び出しのイベントフックではありません。自動更新はエージェントの運用ルール、HTMLと一覧の生成はスクリプトが担当します。

同じテーマは同じ記事IDで更新します。過去の内容はGit履歴で追えます（commitは明示的指示がある場合だけ）。元のassignment_explainer.htmlは移行後も保持しています。

## ブラウザ表示の再検証
```sh
cd docs/learning
PLAYWRIGHT_BROWSERS_PATH=.cache/browsers npx playwright install chromium
npm run verify:browser
```

接続可能なBrowserがない場合のローカルChromium検証です。デスクトップ・モバイル幅で一覧、記事、リンク、横方向のはみ出しを確認し、.tmp/にスクリーンショットを保存します。サイト閲覧者にはNodeやブラウザ検証ツールは不要です。

macOSでGoogle Chromeがインストール済みなら検証スクリプトはその実行ファイルを使います（個人プロファイルは使いません）。別のブラウザ実行ファイルはLEARNING_BROWSER_EXECUTABLEで指定できます。未インストール時のみ上記Chromiumダウンロードが必要です。
