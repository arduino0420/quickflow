# Issue #95: 全画面監査と最小改善

## 範囲と画面の数え方

`bin/rails routes`、controllerのrender/redirect、実HTMLビューを照合した。
HTML画面は23。アクセス前提で分類すると未ログイン4、教師6、生徒3、管理者10。
生徒登録は教師認証が必要な教師画面として数え、管理者ログインは未ログイン側に数える。
`student/assignments#result`は詳細へ303 redirectするため独立画面ではない。
教材/答案PDF、Excel、下書きJSON、health、POST/PATCH/DELETEのredirectは別HTML画面に数えない。
ゲストは同じ画面の読み取り専用状態で、新しい画面ではない。

## 変更と再現結果

| 発見事項 | 変更前の再現 | 最小修正 |
| --- | --- | --- |
| タブの識別が難しい | applicationが一律Quickflow、adminが一律QuickFlow 管理者 | 各HTMLビューの固定titleをh1相当＋QuickFlowへ。生徒詳細/PDFは課題名や個人名を加えず固定の用途名 |
| 教師一覧0件の説明なし | 登録導線と表の見出しだけ表示 | 「登録されている教師はいません。」の1文だけ追加 |
| 成績一覧の条件が失われる | 全クラス/要確認から答案詳細へ進んで戻ると答案の単一クラスへ移動 | 検証済みclassroom_idと許可filterをリンク・保存先へ渡す。任意URLは受け付けない |

既存h1・本文・フォーム構造、ボタン/ルート、採点更新処理、学校/教師の所有scopeは維持。
contextなしは従来どおり答案の所属クラスへ戻る。クラスは課題配信先かつ同校だけ許可し、
配列/Hash/不正形式/未配信/他校を404にする。filterはall/needs_reviewだけ受け渡し、それ以外は無視。
contextは判定更新paramsから独立し、失敗時の再表示にも残す。
再現したCSS不具合はなく、CSS・手書きJS・canvas・座標・footer除外は変更していない。

## 画面別チェック表

全行で新規`screen_audit_spec`が実Chromeの**320/390/768/1280px**をCDPで設定し、
実innerWidth・ページ全体の横幅・表示された入力/選択/ボタンの寸法・titleとh1を検証する。
各状態ごとのfull-page画像は`tmp/issue95/<証跡名>-<幅>.png`へ生成する。
通常以外の全状態をすべての画面で作ったという意味ではなく、該当する状態を以下に区別する。

| 区分 | route / HTML画面 | 今回4幅確認した状態・証跡名 | 既存検証の再利用 |
| --- | --- | --- | --- |
| 未ログイン | `/` | 通常 `home` | footer、教師loginへのキーボード遷移 |
| 未ログイン | `/login` | 通常 `teacher-login` | authentication_ui、認証失敗/秘密値非表示 |
| 未ログイン | `/student/login` | 通常 `student-login` | authentication_ui、1〜3年/1〜10組契約 |
| 教師 | `/students/new` | 通常 `student-registration` | 担当クラスselectを確認、登録/エラーの既存request |
| 未ログイン | `/admin/login` | 通常 `admin-login` | footer、認証切替 |
| 教師 | `/assignments` | 通常/空 `teacher-list`,`teacher-empty` | footerの18件/4幅 |
| 教師 | `/assignments/new` | 通常 `assignment-new` | Japanese error layoutの複数エラー/長文 |
| 教師 | `/assignments/:id` | 要確認/保存後空 `grades-review`,`grades-empty-review` | 全クラス/単一クラス・Excel request |
| 教師 | `/assignments/:id/edit` | 通常 `assignment-edit` | 小テスト名入力失敗request |
| 教師 | `/assignments/:id/submissions/:id` | 長い問題文/feedback・保存/戻る `submission-long` | final_judgment_ui、context成功/失敗/拒否request |
| 生徒 | `/student/assignments` | 採点済み `student-list` | footerの18件/4幅、MVP |
| 生徒 | `/student/assignments/:id` | 提出前長文/採点済み `student-unsubmitted`,`student-graded` | 提出・採点status/MVP request |
| 生徒 | `/student/assignments/:id/pdf_preview` | 長い課題名・描画完了 `student-pdf` | PDF座標保存/復元、4幅提出ボタン、viewport zoom、実worker |
| 管理者 | `/admin` | 通常 `admin-dashboard` | admin account management |
| 管理者 | `/admin/teachers` | 通常/空 `admin-teachers`,`admin-teachers-empty` | teacher list layoutの短いID・操作ボタン3幅（390/768/1280）、footerの19件・4幅 |
| 管理者 | `/admin/teachers/new` | 通常 `admin-teacher-new` | Japanese error layoutの長文/複数入力エラー |
| 管理者 | `/admin/teachers/:id/edit` | 通常 `admin-teacher-edit` | 更新/再設定の既存request |
| 管理者 | `/admin/students` | 通常 `admin-students` | 多数件/ページングの既存spec |
| 管理者 | `/admin/students/new` | 通常 `admin-student-new` | 登録エラー/日本語request |
| 管理者 | `/admin/students/:id/edit` | 通常 `admin-student-edit` | 編集/競合の既存request |
| 管理者 | `/admin/students/:id/confirm_update` (POST render) | 確認 `admin-update-confirm` | 更新の既存request/System |
| 管理者 | `/admin/students/:id/confirm_destroy` | 確認 `admin-delete-confirm` | 削除制約/確認の既存request/System |
| 管理者 | `/admin/students/:id/password_reset/edit` | 通常 `admin-password` | 日本語8桁案内・再設定の既存request |

成績表の`.review-table-container`は`overflow-x:auto`の意図した内部スクロール。
新規監査では内部scrollLeftが移動可能なことを確認し、documentの横はみ出しと区別する。
全23画面に加えて空/提出前/保存後等27状態、108枚を生成。

## 証跡

- [320px 全画面一覧](issue95-evidence/overview-320.jpg): ファイル名の昇順、左から右・上から下。
- [390px 成績→答案→保存後空・PDF](issue95-evidence/flow-390.jpg)
- [768px/1280px 管理者・成績・PDF](issue95-evidence/tablet-desktop.jpg): 上段768px、下段1280px。
- 原寸画像は専用cloneの`tmp/issue95`。新規Systemを実行すると再生成する。

見出し/操作案内/リンク名/ボタン名/label/placeholderを実ビューと画像で照合。
入力の意味を変える文言や新しい登録/管理者案内は追加せず、認証前logoは非リンクを維持。
管理者編集の1〜6年/1〜15組と生徒ログイン1〜3年/1〜10組の差は既存要件確認事項。
今回のUI監査で選択肢・validation・業務ルールを変更しない。
ワイヤーフレームにはtitleと戻り条件の差分があるため、設計資料更新Issue #101/#102 へ引継ぐ。

## 未確認・制限

- 教師一覧の長いID・多数担当クラスを組み合わせた状態は未確認。既存teacher list layoutは短いID・3幅のみ。
- タブレット実機と実際の教師/生徒によるユーザビリティ試験は未実施。Chromeの実viewportで代替した。
- エラー全種類と全画面の直積を4幅で総当たりしたものではない。#94のエラーと既存仕様検証を再利用。
- AI/AWS/本番アクセスはしていない。AI処理は既存RSpec stubと合成fixtureで検証。
- 最終head全RSpecはCIの結果で確認し、関連ローカル成功と区別する。

## 環境・実行結果

専用clone/branch、専用PostgreSQL18.6（127.0.0.1:57595/quickflow_test、
`/tmp/quickflow-issue95-pg`）、clone内`tmp/storage`。
PRIMARY_DATABASE_URLとDATABASE_URLを同じ専用URLへ明示指定し、migrate前にRailsの
host/port/dbと実SQLのhost/port/db/data_directory、Storage rootを照合した。
元作業ツリー/既存DB/他タスクサービスの変更、drop/reset/seed/停止はない。
#110のDemoSeedFixtureを利用する既存specをそのまま再利用し、NOWAITガードは変更しない。

- 関連request第1回: 63例、失敗0。
- 新規全画面System: 3例、失敗0（実23画面・27状態・4幅）。
- RuboCop: 237ファイル、指摘0。Brakeman: 警告0。
- 既存PDF/footer/エラー/ゲスト/成績/Excel/MVP回帰と統合後検証は下記に追記。
- 既存回帰: 57例、失敗0。PDFの保存/復元・実worker/描画・4幅/ズーム、footer、教師一覧の短いID・操作ボタン3幅/19件footer4幅、Japanese error layout、ゲスト、全クラス成績、Excel、MVPを含む。
- 表内スクロール・PDF描画完了待ちを加えた最終関連: 44例、失敗0。108枚を再生成し、一覧・長文答案・保存後空・描画済みPDFの画像を再確認。
- main `09588f380a9b0ce6f09b0f8a22a7ba4d1a498f26`を通常mergeした統合headで、context request＋全画面Systemは16例、失敗0。
  main差分は#95の31ファイルのみ。#50 docsはmain由来で差分には含まれない。

## 独立レビュー・初回CIでの訂正

- 初回監査の`/students/new`は教師認証前に訪問したためloginへredirectされ、教師login画像を重複撮影していた。
  初回の「全23画面確認済み」はこの1画面について不十分だった。生徒登録を教師認証後へ移し、
  担当クラス1年1組のselectを確認した。全audit呼出しで期待するexact path/titleを必須にし、
  現在のh1から期待titleを導出しない。修正後Systemは3例成功し、108枚とcontact sheetを再生成した。
  画面分類も未ログイン4・教師6・生徒3・管理者10へ訂正した。
- 初回CI run39743441923は1769例中12例失敗。全件が既存`teacher_grading_reviews_spec`の
  条件なし答案URL期待値と、承認済みのclassroom_id/filter付きURLとの差だった。
  一覧リンク用の期待値だけを分離して更新し、直接アクセス/保存のcontextなし既存期待は維持。
  同spec全体＋context specは138例、失敗0。無条件のCI再試行は行わず、修正headでCIを実施する。
- mainへ追加された#98の7ファイルはtests/docsのみで#95変更との重複なし。#98の内容は編集しない。
