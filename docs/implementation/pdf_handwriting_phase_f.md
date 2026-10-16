# PDF手書き Phase F 最終品質検証

## 検証範囲

Phase Eをローカルコミットし、`feature/pdf-handwriting-f`で既存機能の異常系・認可・CIを確認する。Phase Fでは画面、業務ロジック、DB構造を変更しない。

Phase Eコミット: `0e42284634c985a04a1b896674ae719bb42e868c`。Phase Fの変更は未ステージ・未コミット。

## 追加修正：PDFサイズとBrakeman

- `bin/brakeman`が最新版確認オプションを強制していた処理を削除した。CI workflowの`bin/brakeman --no-pager`はGemfile.lockで固定されたBrakeman 8.1.0によるスキャンを引き続き実行する。
- 提出POSTだけを対象にするRack middlewareを追加し、HTTP本文をストリームで数えて32MiBを超えた時点で413を返す。通常の他画面・他URLの本文は制限しない。
- 従来アップロードと手書き答案の両方で、PDF本体が25MiBを超える場合はActive Storage保存前に413で拒否する。手書きの場合は下書きを維持し、画面にサイズ案内を表示する。
- 追加RSpecで本文サイズ境界、提出経路以外への非波及、25MiB超過時にSubmission・添付・採点Jobが作られないこと、下書きが維持されることを検証した。
- 関連RSpec: 80件成功、失敗0件。最終全RSpec: 1,380件成功、失敗0件。
- CIと同じ`bin/brakeman --no-pager`: 79 checks、Security Warnings 0、成功。
- `bin/rubocop --cache false -f simple`: 172ファイル、指摘0。JavaScript構文、`git diff --check`も成功。
- development / production DBの変更、OpenAI API呼び出し、commit / push / PR / mergeは行っていない。

## 自動検証結果

- 通信断後の提出状態確認も失敗した場合、筆跡を保持して成功画面へ進まず、再試行前に再確認するJavaScriptテストを追加した。
- 同じクラスの別生徒による署名付き編集コンテキストの流用、および教師・管理者による生徒用下書き・提出APIの使用を拒否するrequestテストを追加した。
- 既存テストで連打、別セッション同時提出、保存と提出の競合、レスポンス喪失、PDF生成失敗、保存失敗、不正PDF、CSRF、他クラス・他校、提出済み再提出を確認した。
- 関連RSpec: 初回F検証では58件成功。サイズ制限を含む最終関連RSpecは80件成功、最終の全RSpecは1,380件成功・失敗0件。実行時は`RAILS_ENV=test DATABASE_URL=postgresql:///quickflow_test`を指定し、既存ガードで実OpenAIクライアントを禁止した。
- LegacyBackfillを全RSpecと同時に個別実行した際、同じtest DBの表ロックが衝突して個別実行のみ10件中6件失敗した。その後、単独実行で10件成功・失敗0件、最終全RSpecでも成功した。並行実行を避ける必要がある。
- CI workflowを確認した。ローカルで`bin/bundler-audit`と`bin/importmap audit`は脆弱性0件、最終`bin/rubocop --cache false -f simple`は172ファイル指摘0件、JavaScript構文チェックと`git diff --check`は成功。CIと同じ`bin/brakeman --no-pager`は79 checks・警告0件で完了。
- CIの`bin/rails db:test:prepare`は実行していない。GitHub ActionsもPhase Fブランチでは未実行。

## 残る問題

- 実際の生徒答案PDFはDBやActive Storageから読み出していない。25MiBは承認された暫定上限であり、運用時のファイルサイズ分布は未確認。
- 開発者が過去に実施したMac Chrome手動確認8項目は成功済み。今回追加したサイズ上限のブラウザ操作、Windows・Chromebook実機、実ネットワーク断、GitHub Actions上での実行は未確認。

## Mac Chrome 手動確認チェックリスト

開発サーバーを起動し、生徒で `http://localhost:3000/student/assignments` を開く。確認用の未提出小テストと教師アカウントを使う。正式提出は取り消せないため、提出するテスト用小テストを選んでから操作する。

1. 生徒の小テスト一覧: 未提出を押すとPDF手書き画面へ進み、提出済みを押すと従来の詳細・結果画面へ進む。
2. PDFへの直接手書き: 全ページが表示され、黒ペンで文字・点・図形を書ける。画面幅を変えても筆跡が問題文上の同じ位置にある。
3. 消しゴム: 小・中・大で線の一部を消し、別ページの筆跡が変わらない。
4. 自動保存・復元: 数秒待ってから再読み込みし、全ページの筆跡と消した結果が戻る。通常の保存状態の文言は画面に表示されない。通信エラー時は警告と再試行を確認する。
5. 提出ボタン: 最終ページの下の「提出する」を押す。連打しても提出は1件で、成功時だけ採点待ちの詳細画面へ進む。ファイル選択は求められない。
6. 既存AI採点と結果表示: 採点処理後、提出済み一覧から採点結果と答案PDFを開き、手書き部分が残っていることを確認する。Codexの検証では実OpenAI APIを呼ばず、RSpecのモックを使用する。
7. 教師の答案確認: 教師アカウントに切り替え、提出した生徒の答案PDFと読み取り・採点結果を開く。
8. 教師の採点修正・成績表示: 必要な問題の判定を修正し、得点と成績一覧に反映されることを確認する。

Windows・Chromebook実機、実ネットワーク切断、GitHub ActionsでのPhase Fブランチ実行はこのローカル検証に含まれない。
