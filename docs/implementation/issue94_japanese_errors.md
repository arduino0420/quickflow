# Issue #94: 日本語エラー表示の最小修正

## 変更範囲

- 既定localeを`ja`にし、既存`accounts.ja.yml`の標準エラー定義を再利用する。
  小テスト名・点数・教材PDF・提出状態・提出日時・答案PDF等の表示属性だけ補完する。
- `Admin::StudentAccountChange#prepare`は描画前に`full_messages`をbaseへコピーする。
  view内だけのlocale変更では不十分なため、共通の既定localeで処理時点も日本語にする。
- 400/422/406を既存404/500と同じ独立HTMLへ揃える。JS・assets・DBは不要。
- 生徒管理/再設定の既存RecordNotFound rescueでHTMLだけ同一の静的404を返す。
  JSON等の空body、status、認可scopeは維持する。他校と不存在は同一応答。
- 再設定の説明を既存の半角数字8桁ルールに合わせる。

入力項目・validation・PasswordPolicy・DB構造・処理status・入力保持・認証・採点・提出は変更しない。
手書きAPIの英語error codeは既存JSで日本語化する契約のため変更しない。

## フォーム/エラー監査

| 対象 | 成功・失敗の既存経路と検証 |
| --- | --- |
| 教師/生徒/管理者ログイン・logout | 既存の日本語固定文言。通常のrole別request specとMVPフローを維持 |
| 生徒自己登録 | 既存日本語属性・view locale。登録成功/重複/無効入力/秘密値非表示を既存specで確認 |
| 管理者の教師/生徒登録 | 成功flash、重複ID/出席番号、確認不一致、入力保持、秘密値非表示。具体的日本語assertion追加 |
| 教師編集・生徒編集/削除・再設定 | 既存日本語の確認/競合/権限エラー。再設定の処理時標準エラー、説明、他校/不存在404を追加確認 |
| 小テスト配信・名前編集 | 成功flash、空名、点数空/0/1.5/abc、教材PDF未選択/不正/25MiB境界。具体的日本語assertion追加 |
| 従来答案PDF提出 | 未選択/偽装/容量・重複・配信scope・正常提出。容量超過の答案PDF属性を日本語assertion追加 |
| 手書き提出/下書き/復旧 | JSがerror codeを日本語化。通信契約、認証/競合、通常処理は変更なし |
| 教師の採点修正/復旧・削除 | 既存日本語固定文言と判定ラベル。既存request/MVPフローを維持 |
| 異常な直URL/CSRF/非対応ブラウザ | 400/404/422/406/500のstatusと安全な日本語静的body、秘密情報非表示をrequest specで確認 |

## localeと表示の影響確認

- `app`内のlocale依存表示呼出しを検索。現在の日付/数値表示に`l`/`localize`/`number_to_*`はなく、
  日時の通信値は`iso8601`、表示数値は明示的な文字列・整数である。
- 成績出力の実装はExcel（CSV経路なし）。列見出し/クラス名は固定日本語、出席番号/得点は明示的integer型。
  `assignment_exports_spec`のファイル名・40行・整数セル・得点・権限境界を回帰確認する。
- 内部Question/AnswerDraft等の英語属性は直接CRUDフォームに公開しない。不要な翻訳や入力を追加しない。
- 実ChromeのCDPでviewportそのものを320/390pxに設定し、実幅もassert。
  配信の複数エラーと教師登録の長文/複数エラーで横はみ出し・formとの重なり・全入力/ボタンの寸法を確認。
  全体スクリーンショットも確認する。既存CSSで収まるためCSS変更なし。

## 検証環境

専用clone/branch、専用PostgreSQLクラスタ（127.0.0.1:57494 / quickflow_test）、clone内専用Storage。
`PRIMARY_DATABASE_URL`と`DATABASE_URL`を同じ専用URLへ明示指定。
migrate前にRailsの設定host/port/db、実SQLのhost/port/db/data_directory、Storage rootを読み取り照合。
元DB/元作業ツリー/他タスクのサービスを変更せず、drop/reset/seed・実AI・本番アクセス・AWS操作なし。

## 実行結果（#110確定head 75a9ee3上）

- 変更前関連request: 200例、失敗0。
- 配信・名前・静的ページを含む最小再検証: request 57例成功。
- 狭幅System: 2例、失敗0。実viewport320/390pxの4画像を確認。
- 管理者/提出/Excel/MVP/ゲストを合わせた回帰: 195例中194例成功。
  失敗1例は`guest_sessions_spec:113`のbeforeで、Demo::Seedが
  `active_storage_attachments`のEXCLUSIVE NOWAITロックを取れなかったもの。
  #110側でも診断中の準備時競合であり、#94でseed/ロック/DBガードは変更しない。
- ゲストrequest/Systemを単独実行: 18例、失敗0。上記競合は複合実行時のみ再現。
- RuboCop: 233ファイル、指摘0。Brakeman: 警告0。`git diff --check`成功。
- 全RSpec/CI/PRは#110の実merge・統合後の結果と区別する。
