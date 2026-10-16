# PDF手書き Phase E 実装・検証報告

## 現在の正式完了状態（PR前整理時点）

Phase EはUI最終調整と開発者のMac Chrome手動確認を含めて正式完了。ローカルコミットは`0e42284634c985a04a1b896674ae719bb42e868c`。その後Phase Fも正式完了し、現在の履歴に含まれる。

- 最終確認済みのローカル検証: 全RSpec 1,380件成功・失敗0件、Brakeman 79 checks・警告0件、RuboCop 172ファイル・指摘0件。PR前総点検でも同じ結果を確認済み。今回の文書整理では再実行していない。
- 開発者によるMac Chrome総合動作確認8項目は成功済み。
- GitHub Actions上のCI成功、Windows・Chromebook実機確認、実通信断試験、実答案PDFサイズ分布は未確認。サイズ上限追加後のブラウザ操作も未確認。

以下は各Phase実施当時の作業記録として保存する。「未コミット」「確認待ち」「未実行」等は当時の状態であり、現在の状態は本節を参照する。Phaseごとの成功件数も当時の検証結果として残す。

## 実施当時の記録

## Gitと作業範囲

- Phase Dローカルコミット: `66843cd238b6f32df20dd5918e3b11e094c2b0b4`
- メッセージ: `feat: autosave and restore handwritten PDF drafts`
- Phase Eブランチ: `feature/pdf-handwriting-e`。上記Dコミットから作成。
- E変更は未ステージ・未コミット。push / PR / mergeなし。
- development / productionへのmigration、既存開発データの更新・削除は行っていない。
- Gem・JSライブラリ、PDF.js / pdf-lib配布物、DB構造、Submissionモデル、採点Job・プロンプト、教師画面、得点計算、Excel出力は変更していない。

## 生徒の操作

未提出の一覧カードは既存の`/student/assignments/:id/pdf_preview`へ直接移動する。提出済み・採点待ち・採点中のカードは従来どおり詳細・結果画面へ進む。未提出の詳細画面には「PDFに解答する」を追加し、互換用の既存アップロードフォームは折り畳み表示にした。アップロードの検証エラー時には展開する。

手書き画面の見出しは小テスト名のみ。全ページ用コンテナの後ろに「提出する」を1個だけ配置した。確認用PDFダウンロードUIは、開発者が主要機能を手動確認した後の追加承認により削除した。長い操作説明・可視ページ番号は追加していない。

## PDF生成と正式提出

1. 一筆を終了し、生成・提出中の入力とツール操作を止める。
2. GETで既存の正式提出状態を確認する。他タブで提出済みでもローカルに未保存操作がある場合は内容を残して停止する。
3. `PdfDraft.flush()`で進行中の保存を待ち、その間に増えた筆跡を追加保存する。未保存・保存失敗・競合・復元失敗時は提出しない。白紙答案も保存バージョンを作ってから提出する。
4. 全ページの操作列を複製し、Phase Cの`generateAnswerPdf`で元PDFと合成する。240dpi、回転・CropBox、元の問題文、消去・書き直しを含む順序付き操作の既存処理を利用する。画面外ページも対象。
5. PDFのBlobと下書きバージョンをFormDataで既存の`Student::SubmissionsController#create`へPOSTする。ファイル選択・手動ダウンロードは不要。
6. サーバーの既存PDF検証を通した後、Active Storageへ実ファイルを先行保存する。課題の行ロック内で教材識別と下書きバージョンを再照合し、既存Submissionを保存する。失敗して添付されなかった今回のBlobは削除する。AnswerDraftは削除しない。
7. 保存後に既存の`AnswerReadingJob`を登録し、既存の詳細・採点中・結果画面へ進む。登録失敗は既存処理でfailedとし、保存済み答案を維持して先生への確認を案内する。

## 競合とエラー

- 既存の課題ライフサイクルadvisory lockを、提出有無確認からPDF保存・Job登録まで保持する。教師の明示削除とも直列になる。
- 手書き提出は課題の行ロックを取得し、下書き保存と直列化する。保存バージョンと教材に不一致があれば409で停止する。
- Submissionの既存DB一意索引を維持する。再試行は既存提出を返し、答案を上書きせず、採点Jobを再登録しない。
- 下書き通信と提出通信には30秒のタイムアウトを設けた。通信失敗・送信タイムアウトで結果が不明な場合はGETで提出状態を再確認する。再確認も失敗した場合は画面を保持し、次の提出操作でも送信前に再確認する。
- 下書きは提出後も残す。既存Dの保存APIが提出済みを拒否し、手書き画面では入力不可となる。
- 生徒は認証情報から決定する。クラス・学校、署名付き編集コンテキスト、教材識別、下書きバージョン、既存CSRF対策を確認する。
- オフラインの未保存分はメモリ上だけに残る。通信エラー中は画面を閉じず、保存を再試行する。競合時は手書きの残る画面を閉じず、先生への確認を案内する。自動マージや強制上書きはしない。

## 主要機能実装時の自動検証（UI最終調整前）

全コマンドでDBを使う場合は`RAILS_ENV=test DATABASE_URL=postgresql:///quickflow_test`を明示した。RSpecの既存ガードで実OpenAI APIクライアントを禁止している。

- 提出・並行実行・JavaScriptの関連テスト: 44件成功、失敗0件。続いてSubmission検証失敗時のBlob片付け・下書き保持のテストを追加し、最終全体実行でも成功。
- 手書き提出から既存の読取・採点Jobまで、OpenAIクライアントをスタブした結合テストに成功。
- 別DB接続・別ログインセッションで実際に競合させ、同時提出でSubmissionとAnswerReadingJobが各1件となること、提出中の自動保存が待機後403となることを確認。
- headless Chromeで一覧→複数ページの手書き・消去・書き直し→正式提出→既存採点待ち画面を確認。保存された答案PDFをPDF.jsで再描画し、全ページ数、元の文字列、消去部分と残った点・画面外ページの黒画素を照合した。
- ChromeのPDF再検証用workerはローカル配信の実workerを使用。system specにはBrowser.setDownloadBehaviorのdenyを指定し、通常のダウンロードフォルダには書き込まない。PDF内容の検証はダウンロード操作を介さずBlob・バイト列で行う。
- 最下部ボタン追加に伴い、既存の3ページ出力テストで固定ツールバーに隠れる入力位置を、隠れない位置へ調整した。回転・CropBox・元の文字列・画素の検証は維持した。
- 最初の全RSpec: 1,370件中2件失敗。どちらも未提出カードが旧詳細画面へ進むという期待値だった。新導線に更新し、既存アップロード・採点・Excelを含む関連83件の再検証は成功。主要機能実装時の全RSpec再実行は1,371件成功・失敗0件（4分5.4秒）。
- 変更したRuby / config / spec 11ファイルのRuboCop: 指摘0。
- JavaScript変更2ファイルの構文チェック、`git diff --check`: 成功。

## 主要機能の手動確認とUI最終調整

開発者がMac Chromeで、一覧から手書き画面への遷移、実際の手書き答案の正式提出、既存AIによる読み取り・採点、提出済み小テストからの結果表示、教師による答案・結果確認に成功したと報告した。これは開発者による確認であり、Codexによる実OpenAI API呼び出しは行っていない。

追加承認されたUI変更:

- 見出しを小テストのタイトルのみとした。ブラウザタイトルと共通レイアウトは変更なし。
- 「未保存」「保存中…」「保存済み」は1px・clip-pathによる読み上げ用通知にし、可視表示とレイアウト余白を除いた。復元中・提出済み通知、保存失敗・通信・競合・教材変更の警告と再試行は維持した。
- 確認用PDFのボタン・説明・専用downloadメソッド・targetsを削除した。存在しないダウンロードを案内していたエラー文も「画面を閉じず先生へ確認」に変更した。保存・復元・競合制御は変更していない。
- 提出ボタンは幅`min(100%, 480px)`、文字18px、高さ52px以上。正式提出の処理と二重送信防止は維持した。
- 緑色の領域は、空のsubmitStatus要素の`role="status"`に共通CSSが緑背景・枠・余白を与えていたことが原因。この画面の提出statusだけを無背景にし、空のp要素はdisplay:noneにした。提出エラーはrole="alert"で表示する。共通CSS・他画面の通知は変更なし。
- PDF出力テストは、専用のテストヘルパーから既存のsnapshotPages / generateAnswerPdfを直接呼ぶ構成に変更した。1・3・10ページ、回転・CropBox、細かな筆跡、消去・書き直し、復元後の出力の検証を維持した。PNG生成失敗のテストは正式提出の失敗・再試行として検証する。
- 競合時は、既存の編集禁止状態を提出ボタンの無効表示にも直ちに反映する。競合の判定・提出の安全チェックは変更なし。

### UI最終調整の変更ファイル

- app/views/student/pdf_previews/show.html.erb
- app/assets/stylesheets/pdf_preview.css
- app/javascript/controllers/pdf_preview_controller.js
- app/javascript/pdf_draft.js（警告文のみ）
- spec/requests/student_pdf_previews_spec.rb
- spec/system/student_pdf_preview_spec.rb
- spec/javascript/pdf_submission_spec.rb
- docs/implementation/pdf_handwriting_phase_e.md

### UI最終調整の検証

- request / JavaScript関連30件: 成功・失敗0件。
- 初回Chrome31件: 30件成功・1件失敗（競合時にボタンが有効な見た目だった）。既存編集禁止状態とボタン表示を同期し、該当1件の再実行は成功。
- UIで変更したRuby spec 3ファイルのRuboCop: 指摘0。
- JavaScript2ファイルの構文チェック・git diff --check: 成功。
- 全RSpec: 最終状態で1,372件成功・失敗0件（4分17.9秒）。Chrome31件を含む。
- 実行: `RAILS_ENV=test DATABASE_URL=postgresql:///quickflow_test bundle exec rspec`。実OpenAI APIは既存RSpecガードで禁止。
- Git: feature/pdf-handwriting-e、HEAD 66843cd238b6f32df20dd5918e3b11e094c2b0b4。既存E変更を含め19ファイルが未ステージ・未コミット。今回のUI修正は上記8ファイル。commit / push / PR / merge / 新規ブランチ作成なし。development / production DB操作なし。

### UI最終調整後のMac Chrome手動確認

URL: `http://localhost:3000/student/assignments`

1. 未提出の小テストを開き、見出しが小テスト名だけで、確認用ダウンロードUI・説明がないことを確認する。
2. 複数ページに書き、消しゴム3サイズで修正する。通常の保存状態が可視表示されないことと、再読み込みで筆跡が復元されることを確認する。
3. 最終ページの下に横長の提出ボタンが1個だけあり、空の緑色の枠がないことを確認する。幅を狭くしてもはみ出さないことを確認する。
4. 提出し、既存の採点・結果画面と答案PDFを確認する。
5. 必要なら未提出の別課題で通信エラーと再試行を確認する。エラーや競合で残った筆跡は画面を閉じると失われる可能性があるため、閉じずに先生へ確認する。

UI最終調整の開発者手動確認は待機中。Windows / Chromebook実機、実際のスクリーンリーダーによる通知は未確認。

## 変更ファイル

- app/assets/stylesheets/pdf_preview.css
- app/controllers/student/assignments_controller.rb
- app/controllers/student/submissions_controller.rb
- app/javascript/controllers/pdf_preview_controller.js
- app/javascript/pdf_draft.js
- app/views/student/assignments/index.html.erb
- app/views/student/assignments/show.html.erb
- app/views/student/pdf_previews/show.html.erb
- config/routes.rb
- spec/javascript/pdf_draft_spec.rb
- spec/javascript/pdf_submission_spec.rb（追加）
- spec/requests/student_assignments_spec.rb
- spec/requests/student_pdf_previews_spec.rb（UI最終調整）
- spec/requests/student_grading_results_spec.rb
- spec/requests/mvp_workflow_spec.rb
- spec/requests/student_submissions_spec.rb
- spec/requests/student_handwritten_submission_concurrency_spec.rb（追加）
- spec/system/student_pdf_preview_spec.rb
- docs/implementation/pdf_handwriting_phase_e.md（この報告書）

Phase Fは実装していない。UI最終調整の手動確認とPhase E正式完了承認を待つ。
