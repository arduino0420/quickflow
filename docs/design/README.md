# 実装と設計図の照合（#102 / #101）

ER・属性の基準は merged main `9704b30fa90867a359d11a8ccf0cff78520aa5d2`。schema・routes・models は今回の表示修正まで変更がなく、ER の構造と画像は維持する。画面遷移は PR #142 の表示実装 `da5763547cee0ba4e834827a5425932ada0a7e35` に照合し、既存の公開 guest 導線とロゴの戻り先を反映した。この表示修正は配備済みで、公開中の通常・guest は `f22a4c8aa6076fc9cb874a14058fd25780860edf`。実装・マージ・配備・提出・学校の受入を区別する。

- [ER 図](../er_diagram.png) / [編集用 SVG](er_diagram.svg)
- [画面遷移図](../screen_transition.png) / [編集用 SVG](screen_transition.svg)
- [全カラム・NULL・型・default・Unique・FK](schema_reference.md)
- [機械可読の基準・制約](constraints.json)
- [原本チェックシート・カタログ・テーブル定義](https://docs.google.com/spreadsheets/d/1G-4Q3SS79nOKc3IJGaaYNftkwM0XktCnIgPAiMZ-1ug/edit)
- [原本ワイヤーフレーム](https://whimsical.com/Lj1FAP2VsasTMNMjFAfDb4)

原本の共有権限・内容はこの変更では更新していない。元の合格済み要件と現在実装の対照表は原本 Sheet を正とする。ここでは重複する要件変更理由を作らず、リポジトリで確認できる実装根拠と提出説明の補足だけを記録する。

## 2026-10-24の差分照合

原本の既存17frameと共有設定を維持し、トップの静止ロゴ・説明2段・3ボタンと教師詳細のguest Excel許可／削除無効表示を修正した。通常トップからguestの3役割選択、入口ロゴから通常トップ、ログイン後ロゴから役割選択への導線は既存トップframeのタイトルと本遷移図に明記した。専用guest入口frameの追加は無料プランのオブジェクト上限で未作成。課金・無関係な要素削除・別boardへの置換はしていない。既存frame内の導線説明は更新済みだが、専用画面の独立ワイヤーフレームは残る資料上の制限である。

DPro原文の第8・9節と設計変更時の再投稿／通知の注記を認証済み教材で再確認した。入口の定型注意文は必須指定ではない。39行の要件と内部状態／CRUDの適用説明は提出対応表で分離している。再投稿・通知・最終提出と学校の受入は未完了。

## 2026-10-23の原本2frame更新（#101）

通常/guestの配備sourceは[acd22fb9](https://github.com/arduino0420/quickflow/commit/acd22fb9e9f7241c3e434a147edc09f5f3a13ef7)。ER/schemaの変更はない。[Whimsical原本](https://whimsical.com/Lj1FAP2VsasTMNMjFAfDb4)のトップと生徒採点結果だけを更新した。

- トップ：大きいQuickFlow文字、元の説明2文、教師→生徒→ゲストの同じ白背景/青文字outlineボタン、閲覧専用guestの説明へ更新。旧「ローカル専用・公開未配備」注記を置換し、各要素の配置/幅をsnapshotで確認した。
- 生徒採点結果：3点の直径1.1rem/上下10px・reduced-motion、準備中/採点中の文言と完了時の自動更新を表現。不要な開き直し案内は示さず、失敗時/PDF不在時の先生への確認は保持。wireframeは静止した仕様表現で、実AIを実行した動画ではない。
- 2frameのIDを保持し、他13wireframeの概要行は前後一致。共有権限は変更していない。下の生成SVG/PNGは旧基準の履歴で、今回更新した原本の複製ではない。本人による審査者閲覧確認・DPro再投稿/メンター通知・学校受入は未実施。追加のメンター解釈承認をゲートにしない。

## 図の読み方とデータの境界

ER は読みやすさを優先した関係・制約一覧型。矢印 `列 → 親表` は実在する DB FK で、相手は親表の id。各 FK は親1件に対し子0件以上。nullable な FK は子から親が0または1件。単一列の FK 自体に Unique はない。複合 Unique は各カードに記載し、全属性は別紙を参照する。

`teacher_classrooms` がモデルの担当関係である。`classrooms.teacher_id` は NULL 可の DB FK として残るが、Classroom の現行モデルには belongs_to :teacher がない。Assignment の current pointer の FK は要求の存在を保証し、同じ課題に属することはモデル検証。`material_blob_id` は必須の識別子だが、ActiveStorage blobs への DB FK はない。

ActiveStorage の多態参照は DB FK ではない。Assignment.material_file と Submission.answer_file はモデル上の添付関連。認証制限表は学校・利用者に FK を持たず、HMAC キーと期限を保持する。`db/cache_schema.rb`、`db/queue_schema.rb`、`db/cable_schema.rb` は運用上の別ストア定義であり、この業務 DB 図に混在させない。

## マージ済み claim 属性と実数の確認

`submissions.processing_claim_stage` (string)、`processing_claim_token` (string)、`processing_claimed_at` (datetime) はすべて NULL 可。default・backfill・Unique index・FK の追加はない。NULL は旧処理の権利不明を意味し、再実行の許可にならない。新規提出と既存の適格な採点復旧で ready を確定し、reading / grading の短い claim・外部処理・再検証を分ける。経過時間による token の奪取や新しい読取再試行 UI はない。根拠は migration `20261022110000`、`SubmissionProcessingClaim`、[マージ済み #46 の実装説明](../implementation/issue46_ai_claims.md)。この資料確認は live migration・デプロイの実施を意味しない。

モデル数・表数・列数は renderer の `inventory()` が現在のファイルから算出し、`constraints.json` / `validation.json` に表名・モデルファイルとともに保存する。`ApplicationRecord` は抽象基底として除き、ActiveStorage の3表はアプリの具象モデル数に含めない。cache / queue / cable は別ストアの表名と個数を別集計する。

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
| ゲスト | `Demo::Guest` の有効条件・READS allowlist、`ApplicationController#guard_guest_session`。合成データ専用・書込禁止。通常の認証入口と分離した公開 guest へリンク。入口ロゴは通常トップ、ログイン後のロゴは guest 役割選択へ戻る。教師 Excel は許可、削除は無効ボタンのみ | `spec/requests/guest_sessions_spec.rb`。実装・隔離の既存記録は [#93](../implementation/issue93_production_demo.md) |
| エラー・共通 UI | `public/404.html` / `500.html` はトップへのリンク。認可エラーの head 応答もあり、全エラーを同一ページとはしない。role 別ヘッダーと共通 footer | `spec/requests/error_pages_spec.rb`, `footer_spec.rb`、[画面幅の既存監査](../implementation/issue95_screen_audit.md) |

PDF の内容不正は入力画面または手書き提出のエラーで案内する。PDF 確認基盤の利用不可は 503。手書きと下書きを保持する。根拠は `PdfReadabilityValidator`、配信・提出 controller と `pdf_preview_controller.js`。既存検証は `spec/requests/pdf_readability_spec.rb` および `spec/system/student_pdf_preview_spec.rb`。

## 提出時の説明と未完了項目

旧図の教師・生徒の公開 signup、初期設定、rails_admin を現行の役割別認証・管理者管理へ置換した。直接手書き・自動保存・結果状態・確認と復帰、教師の配信先選択・成績・Excel、条件付き採点再開を追加した。ER は学校・管理者・担当関係・下書き・認証制限・正答生成要求・ActiveStorage を現在の制約で区別した。これは実装に合わせた資料更新であり、新機能の実装ではない。

原本の合格済み要件からの変更理由・承認経緯は、原本 Sheet と確認記録で確定する必要がある。このリポジトリ調査だけから理由を推測していない。#101 の各画面のワイヤーフレームの配置・PC/タブレット/スマホ表現と共有閲覧確認は原本側で照合する。この遷移図はワイヤーフレームの代替ではない。

#102の技術資料照合/差分説明は既存の完了記録を参照。#101の対象2frame差分は上記のとおり反映したが、人間による審査者閲覧確認・DPro再投稿・メンター通知・実施記録が残る。再投稿・通知済みとは記録しない。

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

`verify_diagrams.py` は現行ファイルから計数し、全 claim 属性の型・NULL・制約、schema/routes のハッシュ、全ローカルリンク、SVG/PNG の寸法と再生成一致を確認する。[機械可読の結果](validation.json) に各成果物の SHA-256 を記録する。両 PNG の日本語・文字サイズ・余白・矢印を画像で確認し、カード内テキストの幅超過も renderer で検出する。既存 PNG の公開パスを維持している。

この資料更新のローカル確認で Rails のテストや DB は起動していない。上の spec は追跡用の実在ファイル一覧であり、今回成功したとの主張ではない。リポジトリの GitHub Actions CI 結果は PR の対象 head に付くチェックで確認する。
