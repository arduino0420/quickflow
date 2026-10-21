# Issue #79 第2段階：答案画面の認証失効後再開

## 操作

保存または提出が認証失効で拒否されたら、答案画面は開いたままにする。案内リンクで別タブを開き、同じ生徒の新しいパスワードでログインする。元の答案タブに戻って「再開を確認」を押す。確認が通ると、未保存の手書きは現在の画面から既存の自動保存経路で保存され、提出ボタンを使えるようになる。通信障害なら同じボタンを再度押せる。

ブラウザのタブを閉じる、再読み込みする、ブラウザを終了する場合、未保存の筆跡を保持する保証はない。共有端末に答案のローカル永続コピーは作らない。

## 安全性

- 開始時の生徒・学校・クラス・課題・教材の指紋を署名した再開コンテキストを答案ページに持つ。再開確認APIは現在のログイン済み生徒・所属クラス・同じ学校の教師が配布した課題・教材の指紋と照合する。既存の下書きコンテキストも要求する。
- 再開APIは読み取り専用で、現在のセッションに対応するCSRFトークンを、未提出で条件が合う場合だけ返す。画面側は古いCSRFトークンをその後に置き換える。保存・提出APIは従来のCSRF検証を維持する。
- サーバーの下書き版が表示画面の版と同じなら再開できる。保存応答が失われた可能性がある場合のみ、最後に送ったスナップショットとサーバーの内容が完全に一致すれば新しい版を採用する。差分があれば停止し、画面の筆跡を変更しない。再開後の保存も既存の `expected_version` と署名済みコンテキストで拒否され得る。
- 提出済みならサーバーの提出識別子とこの画面で作った識別子・筆跡改訂番号を比較する。同一の提出と確認できた場合だけ結果画面へ進む。それ以外は停止する。提出前の確認と最終POSTでは既存の版照合・二重提出防止を使用する。
- 401とCSRF失敗だけを再ログイン案内に分類する。一般のネットワーク障害や版競合は認証復帰とは扱わない。401後に自動保存の再試行を止め、画面を自動で再読み込みしない。

## 対象ファイル

第2段階のアプリ変更は `app/services/answer_draft_context.rb`、`app/controllers/student/pdf_previews_controller.rb`、`app/controllers/student/answer_drafts_controller.rb`、`app/controllers/student/submissions_controller.rb`、`config/routes.rb`、`app/views/student/pdf_previews/show.html.erb`、`app/javascript/pdf_draft.js`、`app/javascript/controllers/pdf_preview_controller.js`。追加・更新テストは `spec/requests/student_answer_recovery_spec.rb`、`spec/javascript/pdf_recovery_spec.rb`、`spec/javascript/pdf_draft_spec.rb`、`spec/system/student_pdf_preview_spec.rb`。第1段階の未コミット変更は保持する。

## 残る制約

閉じたタブの未保存筆跡は戻せない。版競合、教材変更、別生徒ログイン、異なる提出がある場合に、答案を自動統合しない。回復不能の際は画面を保持して教師に確認する。実機のiPad・Apple Pencil、Chromebook・Windows端末はこの隔離環境では試験していない。

## ローカル検証

- GitHubのmainは作業基点 `ec1ddcca206c02d424f04e3fd78020b2a48d7f46` と一致。作業ブランチは `fix/issue-79-authentication`、HEADは同じコミットのまま。
- 専用PostgreSQL（Unixソケット、ポート55479、外部TCPなし、既存の共有DBとは別）で最終全RSpec **1,636件・失敗0件**。ログは `/private/tmp/quickflow-issue79-auth-stage2-final-rspec.log`。第1段階の共有IP30人、試行制限、旧セッション失効も含む。
- 中間の全RSpecは1,635件・失敗1件。401案内の表示でキャンバス位置が下がり、既存ブラウザテストのペン移動先が画面外になった。テストでキャンバスを表示領域へスクロールしてから操作し、単独再実行後、最終全件を成功させた。アプリの筆記座標や操作処理は変更していない。
- RuboCop **212ファイル・指摘0**、Brakeman **Errors 0・Security Warnings 0**、bundler-audit **該当なし**、importmap audit **該当なし**、`git diff --check` 成功。importmapの既存ローカル pin は監査対象0件であり、PDF.js/pdf-libの実機安全性をこの結果だけで保証しない。
- Chrome実ブラウザで、同一生徒の別タブ再ログイン後の保存・提出、未保存筆跡保持、別生徒の拒否、通信障害後の再試行、版競合停止、401を受けた提出の再送、サーバーで完了した提出の同一識別子照合を確認。既存の複数ページ・消しゴム各サイズ・筆記・スクロール・PDF生成・提出フローも全RSpecに含む。
- 元の未コミット18ファイルとIssue #78の回帰テストは保存時のSHA-256・Git状態に一致。退避アーカイブも保持。隔離DBは検証後に停止し、データとログを残した。

commit、push、PR作成、マージ、AWS・本番DB操作は行っていない。
