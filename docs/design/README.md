# 実装と設計図の照合（#102 / #101）

基準は main `1404453a24dce4f3661a7c6aee7fc570e8f6b683`。現在のマージ済み実装に対する #102 の部分更新。#46 の未マージ属性を含まない。#46 がマージされた後、実際の schema・関連・復旧条件を確認して追補し、最終受入とする。

- [ER 図](../er_diagram.png) / [編集用 SVG](er_diagram.svg)
- [画面遷移図](../screen_transition.png) / [編集用 SVG](screen_transition.svg)
- [全カラム・NULL・型・default・Unique・FK](schema_reference.md)
- [機械可読の基準・制約](constraints.json)
- [原本チェックシート・カタログ・テーブル定義](https://docs.google.com/spreadsheets/d/1G-4Q3SS79nOKc3IJGaaYNftkwM0XktCnIgPAiMZ-1ug/edit)
- [原本ワイヤーフレーム](https://whimsical.com/Lj1FAP2VsasTMNMjFAfDb4)

原本の共有権限・内容はこの変更では更新していない。元の合格済み要件と現在実装の対照表は原本 Sheet を正とする。ここでは重複する要件変更理由を作らず、リポジトリで確認できる実装根拠と提出説明の補足だけを記録する。

## 図の読み方とデータの境界

ER は読みやすさを優先した関係・制約一覧型。矢印 `列 → 親表` は実在する DB FK で、相手は親表の id。各 FK は親1件に対し子0件以上。nullable な FK は子から親が0または1件。単一列の FK 自体に Unique はない。複合 Unique は各カードに記載し、全属性は別紙を参照する。

`teacher_classrooms` がモデルの担当関係である。`classrooms.teacher_id` は NULL 可の DB FK として残るが、Classroom の現行モデルには belongs_to :teacher がない。Assignment の current pointer の FK は要求の存在を保証し、同じ課題に属することはモデル検証。`material_blob_id` は必須の識別子だが、ActiveStorage blobs への DB FK はない。

ActiveStorage の多態参照は DB FK ではない。Assignment.material_file と Submission.answer_file はモデル上の添付関連。認証制限表は学校・利用者に FK を持たず、HMAC キーと期限を保持する。`db/cache_schema.rb`、`db/queue_schema.rb`、`db/cable_schema.rb` は運用上の別ストア定義であり、この業務 DB 図に混在させない。

## 画面単位の実装根拠

`config/routes.rb`、全 `app/models/*.rb`、各 role の controller・view を照合した。略記 `…` は該当 role の assignment 配下で、独立した画面の追加を意味しない。

| 対象 | 現行の根拠・範囲 | 既存の検証ファイル（今回の実行結果ではない） |
|---|---|---|
| 認証入口 | `sessions` / `student_sessions` / `admin/sessions`、`AuthenticationThrottle`。公開 signup はない | `spec/requests/authentication_ui_spec.rb`, `authentication_security_spec.rb` |
| 管理者の登録・編集 | `admin/teachers`, `admin/students`, `admin/student_password_resets`。同じ学校、確認・再認証を伴う更新 | `spec/requests/admin_account_management_spec.rb`, `admin_students_spec.rb`, `admin_teacher_editing_spec.rb` |
| 教師のクラス・生徒 | `StudentsController` の登録は教師認証と担当クラス限定。独立したクラス CRUD 画面はない。配信先は学校内クラス | `spec/requests/student_registration_spec.rb`, `teacher_classroom_access_spec.rb` |
| 配信・成績 | `AssignmentsController` の作成者スコープ、配信詳細のクラス選択、答案確認・判定保存、Excel | `spec/requests/assignments_spec.rb`, `assignment_exports_spec.rb`, `teacher_grading_reviews_spec.rb` |
| 生徒の解答 | 未提出一覧から PDF 手書きへ直接移動。下書き自動保存・提出、提出済みは詳細で状態と結果。従来アップロードは副導線 | `spec/requests/student_pdf_previews_spec.rb`, `student_answer_drafts_spec.rb`, `student_handwritten_submission_concurrency_spec.rb`, `student_grading_results_spec.rb` |
| 手書きの失敗・復帰 | `pdf_previews/show` と `pdf_draft.js`、`Student::AnswerDraftsController#recovery`。認証切れは別タブ再ログイン後に確認。教材変更・版競合・保存失敗を区別 | `spec/requests/student_answer_recovery_spec.rb`, `spec/system/student_pdf_preview_spec.rb` |
| 採点の復旧 | `SubmissionsController#resume_grading`, `Recovery::GradingRecovery`。フラグ ON の教師のみ、failed または停止 grading 候補。サーバー側の追加安全条件で拒否されうる。読取再実行操作を追加していない | `spec/requests/teacher_grading_recovery_concurrency_spec.rb` |
| ゲスト | `Demo::Guest` の有効条件・READS allowlist、`ApplicationController#guard_guest_session`。合成データ専用・書込禁止。既定 OFF。実装の存在を公開 URL の存在と扱わない | `spec/requests/guest_sessions_spec.rb`。実装・隔離の既存記録は [#93](../implementation/issue93_production_demo.md) |
| エラー・共通 UI | `public/404.html` / `500.html` はトップへのリンク。認可エラーの head 応答もあり、全エラーを同一ページとはしない。role 別ヘッダーと共通 footer | `spec/requests/error_pages_spec.rb`, `footer_spec.rb`、[画面幅の既存監査](../implementation/issue95_screen_audit.md) |

PDF の内容不正は入力画面または手書き提出のエラーで案内する。PDF 確認基盤の利用不可は 503。手書きと下書きを保持する。根拠は `PdfReadabilityValidator`、配信・提出 controller と `pdf_preview_controller.js`。既存検証は `spec/requests/pdf_readability_spec.rb` および `spec/system/student_pdf_preview_spec.rb`。

## 提出時の説明と未完了項目

旧図の教師・生徒の公開 signup、初期設定、rails_admin を現行の役割別認証・管理者管理へ置換した。直接手書き・自動保存・結果状態・確認と復帰、教師の配信先選択・成績・Excel、条件付き採点再開を追加した。ER は学校・管理者・担当関係・下書き・認証制限・正答生成要求・ActiveStorage を現在の制約で区別した。これは実装に合わせた資料更新であり、新機能の実装ではない。

原本の合格済み要件からの変更理由・承認経緯は、原本 Sheet と確認記録で確定する必要がある。このリポジトリ調査だけから理由を推測していない。#101 の各画面のワイヤーフレームの配置・PC/タブレット/スマホ表現と共有閲覧確認は原本側で照合する。この遷移図はワイヤーフレームの代替ではない。

#102 は原本 Sheet・テーブル定義との最終一致、#46 マージ後の schema 再確認、提出用説明の原本統合が残る。#101 は原本ワイヤーフレームの最終一致と、人間による DPro 再投稿・メンター通知・実施記録が残る。再投稿・通知済みとは記録しない。

## 再生成

`build_diagrams.py` は図の編集元。共通のプリミティブから SVG と PNG を同時生成する。SVG は標準の編集可能なベクター形式で、図の変更は Python のカード／矢印定義を修正して再生成する。Rails と DB は不要。

```sh
python3 -m venv /tmp/quickflow-diagrams-venv
/tmp/quickflow-diagrams-venv/bin/pip install Pillow==12.0.0
/tmp/quickflow-diagrams-venv/bin/python docs/design/build_diagrams.py
/tmp/quickflow-diagrams-venv/bin/python docs/design/verify_diagrams.py
```

Pillow は公式 PyPI のパッケージを一時環境に導入する。アプリの依存関係は変更しない。標準フォントは macOS のヒラギノ。別環境では `DIAGRAM_FONT` に日本語対応 TrueType/OpenType のパスを指定する。フォント差のため PNG が変わる場合は再度等倍で確認する。新しい schema を取り込む際は script の BASELINE と図の要約も実装と照合し直す。自動生成の詳細だけ更新して完了扱いにしない。

## この版の確認記録

`verify_diagrams.py` が成功：17表・21 FK・15 Unique index、schema/routes のハッシュ、全ローカルリンク、SVG/PNG の寸法と再生成一致を確認。[機械可読の結果](validation.json) に各成果物の SHA-256 を記録する。両 PNG の日本語・文字サイズ・余白・矢印を画像で確認し、カード内テキストの幅超過も renderer で検出する。既存 PNG の公開パスを維持している。

この資料更新のローカル確認で Rails のテストや DB は起動していない。上の spec は追跡用の実在ファイル一覧であり、今回成功したとの主張ではない。リポジトリの GitHub Actions CI 結果は PR の対象 head に付くチェックで確認する。
