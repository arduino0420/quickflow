# PDF手書き Phase D 実装・検証報告

## 現在の正式完了状態（PR前整理時点）

Phase Dは正式完了。ローカルコミットは`66843cd238b6f32df20dd5918e3b11e094c2b0b4`で、Phase Fまでの履歴に含まれる。developmentへのmigration適用・バックアップ検証・手動確認は完了済み（詳細は下記の正式完了記録）。

Phase Eで通常の保存状態は読み上げ用通知となり、確認用PDFダウンロードUIは削除された。現在は競合・保存失敗時に画面を保持し、警告と再試行を案内する。下記の可視「保存済み」表示や確認用PDFへの退避手順はPhase D当時の仕様である。

- 最終確認済みのローカル検証: 全RSpec 1,380件成功・失敗0件、Brakeman 79 checks・警告0件、RuboCop 172ファイル・指摘0件。PR前総点検でも同じ結果を確認済み。今回の文書整理では再実行していない。
- 開発者によるMac Chrome総合動作確認8項目は成功済み。
- GitHub Actions上のCI成功、Windows・Chromebook実機確認、実通信断試験、実答案PDFサイズ分布は未確認。サイズ上限追加後のブラウザ操作も未確認。

以下は各Phase実施当時の作業記録として保存する。「未コミット」「確認待ち」「未実行」等は当時の状態であり、現在の状態は本節を参照する。Phaseごとの成功件数も当時の検証結果として残す。

## 実施当時の記録

## 状態

Phase Dは開発者のMac Chrome手動確認・正式承認により完了。自動保存・復元と、明示的な小テスト削除時の下書き連動削除を実装済み。
以下の過去の検証・適用計画は実施時点の記録であり、最新状態は次の完了記録を参照する。

### 正式完了記録

- migration `20261016090000` はdevelopment DBへ適用済み。answer_drafts作成とRailsからの認識は正常。productionへの適用は行っていない。
- 適用前にDB・Active Storageのバックアップを取得・検証済み。保存先: `/Users/yukinori-herzegovina/workspace/quickflow-backups/phase-d-20261016T050141Z-77d58cdc/`。
- 適用後の読み取り検証で、既存の生徒・教師・小テスト・提出・採点データの件数、内容のハッシュ、既存テーブル構造・シーケンス、添付ファイルに想定外の変化なし。
- 開発者がMac Chromeで黒ペン入力、約2.5秒後の自動保存、再読み込み復元、消しゴム小・中・大の復元、複数ページ保持、再ログイン復元、別Chromeプロファイル復元、復元答案PDF生成・ダウンロードの8項目すべてに成功。
- 直近の全RSpecは1,351件成功・失敗0件。development DBのmigration適用作業時にはRSpecを再実行していない。
- Windows・Chromebookの実機確認は未実施。

- Cコミット: `6712b1cfb6a65195b4f42e80bd2b2deff6b069e8`
- Dブランチ: `feature/pdf-handwriting-d`（上記コミットから分岐）
- Dは未ステージ・未コミット。push / PR / mergeなし。
- 新しいGem / JSライブラリなし。PDF.js / pdf-libの配布物は変更なし。

## 保存・復元

- サーバーの`answer_drafts`に、生徒・小テスト単位で操作データをJSONB保存する。PDFファイル自体は保存しない。
- 一筆の終了・消去の終了から2.5秒のdebounce。pointermoveごとの通信は行わない。
- 全ページのPDF座標・操作ID・種類・色・幅・座標列を操作順のまま保存する。表示用Canvasの有無に依存しない。
- 送信時点のコピーを直列送信し、保存中に増えた操作は次の保存へ残す。
- 下書き復元完了まで入力を禁止する。復元後もPDF.jsのviewportで再描画し、回転・CropBox・画面幅変更に対応する。
- ログアウト後・別セッションの同じ生徒も、認証付きGETから復元できる。
- 復元した操作はPhase CのPDF生成にも使用する。
- 初回保存前は「未保存」、通信中は「保存中…」、最新の完了操作がサーバーに保存された場合だけ「保存済み」。保存の再試行ボタンを設ける。
- 通信失敗時はメモリ上の操作を残す。再試行時はGETで保存状態を確認する。応答だけが失われた可能性がある場合も、直前に送った内容との完全一致を確認してからバージョンを引き継ぐ。
- 競合時は自動保存・新規入力を停止する。未保存分を確認用PDFへ退避し、別タブでサーバー保存済みの下書きを確認する。自動マージ・強制上書きは行わない。
- 通常のリンク移動・ブラウザ終了では未保存の確認を出す。ブラウザや移動方法によって確認が抑制される場合があるため、「保存済み」を確認してから閉じる。ブラウザの強制終了、停電、OSによる終了等まで未保存データを保証するものではない。

## 共用端末・セキュリティ

IndexedDB / localStorageは採用していない。共有端末への永続的な答案残存、ログアウト時の消去漏れ、ローカルとサーバーの競合を避け、今回はサーバー保存を優先した。
このためオフライン中に画面を閉じた場合、未保存の操作は復元できない。ブラウザデータを消してもサーバー保存済みの下書きは削除されない。

- 認証済みの生徒をサーバー側で特定する。クライアントのstudent_idを所有者として使用しない。
- 課題の配信先クラスと教師の所属校を毎回確認する。
- 署名付きの画面コンテキストを生徒・課題・教材に結び付け、古いタブが別の生徒のセッションで保存することを拒否する。
- 教材の識別にはActive Storageのblob ID・checksum・サイズに基づくSHA-256文字列を使用する。教材差し替え時は元の下書きを保持して停止する。古いblobへの外部キーは追加しない。
- 試作画面のPDF取得にも同じ教材コンテキストを付ける。従来のアップロード・教材表示フローには引き続き対応する。
- APIは既存のCSRF保護を維持し、同一オリジンの認証付きGET / PUTを使用する。レスポンスはprivate, no-store。
- JSON操作データ、SQLのpage_data値、コンテキストのURLパラメータをログのフィルター対象にする。
- Railsのパラメータ解析・ログ処理より前に本文のサイズとJSONを検査する。Content-Lengthがなくても読み取り量を制限する。
- 保存APIはAssignmentの行ロック内で提出済み状態・教材・更新バージョンを再確認する。既存Submissionがあれば、そのステータスを問わず新規作成・更新を禁止する。
- Submission / submitted_at / AnswerReadingJob / AI採点を保存処理から操作しない。

## データ設計・上限

| カラム | 型・用途 |
|---|---|
| id | 主キー |
| student_id | 生徒の外部キー、NOT NULL |
| assignment_id | 小テストの外部キー、NOT NULL |
| material_fingerprint | 64文字の教材識別、NOT NULL |
| format_version | integer、形式1 |
| page_data | JSONB、ページ番号と順序付き操作列 |
| lock_version | integer、Active Record楽観的ロック |
| created_at / updated_at | 作成・更新日時 |

student_id・assignment_idそれぞれの索引と、両者の組のユニーク索引を追加する。既存テーブルのカラム・データは変更しない。DB CHECK・DBのON DELETE CASCADEは追加しない。教師の明示的な小テスト削除時だけ、既存削除サービス内で関連下書きを削除する。

初期上限は200ページ、計10,000操作・100,000座標点、JSON操作データ4MiB。リクエスト全体は4MiB+16KiBまで。
座標は有限数で絶対値1,000,000以下、ペン幅1.2、消しゴム幅4/8/12、黒色に限定し、重複操作IDや未知の属性・形式を拒否する。
復元時には実際のページ数と各ページのPDF範囲も照合する。上限・形式エラー時も未保存の画面データを破棄せず、確認用PDFへの退避を案内する。

## 検証

実行コマンドはすべて`RAILS_ENV=test DATABASE_URL=postgresql:///quickflow_test`を指定した。

- `bin/rails db:migrate`: `20261016090000_create_answer_drafts`のみ追加適用。schema.rbはこの処理で自動更新。
- 連動削除修正後の全RSpec: 1,351件成功、失敗0件（4分59秒）。
- 削除サービス・教師削除API・下書きAPIの関連RSpec: 37件成功、失敗0件。
- 今回変更したRuby 5ファイルの静的チェック: 指摘0。差分チェックも成功。
- 検証内容: 保存・全ページ復元、消しゴム3幅、書く→消す→書く、再ログイン・別セッション、保存途中の入力、通信失敗、応答喪失時の再試行、複数タブ競合、復元前の入力禁止、教材差し替え、権限、CSRF、不正/過大JSON、提出済み禁止、PDF再生成、既存削除と下書き連動削除のロールバック、他課題の下書き保護、削除後・削除と重なった保存要求の拒否。
- 実OpenAI API呼び出しはRSpecの既存ガードにより禁止されている。
- Ruby静的チェック、JavaScript構文チェック、git diff --checkを実行。
- Windows / Chromebookの実機と開発DBでの手動確認は未実施。
- LegacyBackfillの既存のロック依存の不安定性は修正対象にしていない。

## 変更・追加ファイル

- `app/models/assignment.rb`
- `app/services/assignment_deletion.rb`
- `spec/services/assignment_deletion_spec.rb`
- `spec/requests/assignment_deletion_spec.rb`
- `app/models/answer_draft.rb`
- `app/services/answer_draft_context.rb`
- `app/controllers/student/answer_drafts_controller.rb`
- `app/controllers/student/pdf_previews_controller.rb`
- `app/controllers/student/assignments_controller.rb`
- `app/javascript/pdf_draft.js`
- `app/javascript/pdf_ink.js`
- `app/javascript/controllers/pdf_preview_controller.js`
- `app/views/student/pdf_previews/show.html.erb`
- `app/assets/stylesheets/pdf_preview.css`
- `config/routes.rb`
- `config/importmap.rb`
- `config/initializers/answer_draft_request_limit.rb`
- `config/initializers/filter_parameter_logging.rb`
- `lib/answer_draft_request_limit.rb`
- `db/migrate/20261016090000_create_answer_drafts.rb`
- `db/schema.rb`（test migrationによる自動更新）
- `spec/models/answer_draft_spec.rb`
- `spec/requests/student_answer_drafts_spec.rb`
- `spec/javascript/pdf_draft_spec.rb`
- `spec/requests/student_pdf_previews_spec.rb`
- `spec/system/student_pdf_preview_spec.rb`
- この報告書

## 開発DBへの適用計画（未実行・別途承認が必要）

1. 実装・テスト結果、既存の削除条件を維持した下書き連動削除の仕様を確認する。
2. 使用中のDBがquickflow_developmentであること、接続設定・pending migrationを確認する。作業中のアプリを止める。
3. 開発者が既存のバックアップ運用を確認する。Active Storageの保存先も既存手順でバックアップを確認する（DBのdumpにはPDF本体は含まれない）。例: `pg_dump -Fc -d quickflow_development -f <安全な保存先>/quickflow_before_phase_d.dump`。`pg_restore --list <バックアップファイル>`で一覧を確認し、別DBで復元確認できることを確かめる。既存DBへ復元しない。
4. 開発者の別途承認後に、この1本だけを適用する予定:

```sh
RAILS_ENV=development DATABASE_URL=postgresql:///quickflow_development bin/rails db:migrate:up VERSION=20261016090000
```

5. 新規テーブル・索引・外部キーの存在、既存主要テーブルの件数を読み取り専用で照合し、アプリを再起動する。

新規の空テーブルを追加する非破壊的なmigrationだが、下書き作成後の親課題削除には外部キーの影響がある。development / productionへの適用、DB reset/drop/purge、既存データの削除は今回実行していない。

## Mac Chromeの手動確認（開発DB適用の承認・実行後）

1. 生徒ログイン後、従来の`http://localhost:3000/student/assignments/<ID>/pdf_preview`を開く。
2. 複数ページに書き、消しゴム小・中・大で修正し、書き直す。「保存済み」を待つ。
3. 再読み込み、幅変更、ログアウト→再ログイン後に同じ位置・消去結果へ戻ることを確認する。
4. 同じ生徒で別Chromeプロファイル等からログインし、サーバー保存分を復元する。
5. 確認用PDFを生成して復元後の筆跡・消去跡を確認する。
6. 2タブで同じ課題を開き、一方を保存してから他方を編集する。競合で停止し、サーバー保存分と未保存分の双方が勝手に失われないことを確認する。未保存分はPDFに退避し、別タブで保存済み下書きを確認する。
7. Chrome DevToolsで一時的に通信を止め、保存失敗を確認する。画面を閉じず通信を戻し、再試行で保存・復元できることを確認する。

## 小テスト削除との整合（追加承認に基づき実装済み）

教師が既存の削除操作を明示的に実行した場合だけ、AssignmentDeletion内で対象課題のAnswerDraftをdestroy!する。Assignmentにhas_many :answer_draftsを追加するが、dependent: :destroyは付けず、保存・復元・ログアウトや別の経路へ削除を広げない。

既存の教師権限・所属・採点データ整合性チェック、ライフサイクルロック、親課題の行ロックを維持する。同じトランザクション内で下書きを削除してから、既存の提出・設問等の削除処理を実行する。後続の削除が失敗すると下書きも復元される。外部キーは維持し、追加migrationは不要。

下書き保存も親課題の行ロックを取得するため、保存と削除が重なった場合は直列になる。削除後の保存は課題の検索、または取得済み課題のロック時の再読み込みで404になり、下書きを再作成しない。新たなSubmissionや採点結果を削除対象に追加しない。別課題の下書き・生徒・成績は保持する。

追加修正は関連37件および全RSpec 1,351件で成功した。development / productionへのmigration適用・既存開発データの変更・Git commit / push / PR / mergeは行っていない。
