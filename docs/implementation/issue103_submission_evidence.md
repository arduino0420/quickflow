# #103 必須39項目の証跡対応（提出未完了）

本タスクは親が認証済み原文から確認した要約と既存草案を再利用した二次照合。認証ブラウザ/DProを独立再読していない。追加メンター解釈承認をゲートにしない。


### 原文との対応・証拠の基準

原文: [DPro curriculum 3027](https://diver.diveintocode.jp/curriculums/3027)。認証済み原文の確認記録は2026-10-22（原文更新日時2026-09-28 06:48 JST）。下表の要件欄は受領した39項目の**意味を保持した要約**であり、逐語引用ではない。番号はカテゴリ内の順序。適用判断を要件本文に混ぜず後段へ分離した。本草案は原文確認記録と既存証拠文書を基にした二次照合である。

コード照合基準: [main 9704b30](https://github.com/arduino0420/quickflow/commit/9704b30fa90867a359d11a8ccf0cff78520aa5d2)（2026-10-23）。親タスク確認の[main CI39876600200](https://github.com/arduino0420/quickflow/actions/runs/39876600200)は全4ジョブ成功、RSpec 2,034例・失敗0。これはSystem/Modelを含むsuite全体の件数で、各区分単独の件数ではない。実行定義は[CI](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/.github/workflows/ci.yml)（Ubuntu、Ruby4.0.6、PostgreSQL service、Chrome System、AI stub）を参照。本タスクはコード/資料の読取照合のみでテストや配備を実行していない。文書最終headのCIと提出時mainは確定後に追記する。

状態「実装・既存試験証拠あり」は指定sourceと過去監査/上記CIの範囲。**merged / deployed / submitted / 学校での受入**を別々に扱う。全39項目合格や公開実機検証済みとはしない。画像は架空データのChrome証拠（#95と下記#99）であり実端末・実学校の受入証拠ではない。

| 要件 | 対応する実装・資料 | テストや画面の証拠 | 状態 |
| --- | --- | --- | --- |
| 開発1: Ruby on Railsを使用 | [README](../../README.md)、[Gemfile.lock](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/Gemfile.lock) Rails8.1.4 | [Ruby4.0.6](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/.ruby-version)、上記CIのbundle/setupとsuite成功 | 基準source/CIで確認／配備runtimeは未確認 |
| 開発2: HerokuまたはAWS EC2へデプロイ | #51/#99配備runbook、AWS方針 | [runbook](issue51_predeployment_runbook.md)。最終main/imageの実EC2稼働・公開URL・TLS証拠は未取得 | 配備・公開検証未完了 |
| 開発3: トップページがある | [home view](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/views/home/index.html.erb)、#89/#95 | [画面監査](issue95_screen_audit.md): `home`、4幅Chrome・title/h1/exact path | 限定証拠あり／最終照合待ち |
| 開発4: トップでサービス・コンセプト・機能が分かる | [home view](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/views/home/index.html.erb)、[home spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/home_spec.rb) | #95 `home`と[320px一覧](issue95-evidence/overview-320.jpg)。本文3要素と最終公開画面の対応を追記 | 最終本文・画面確認待ち |
| 開発5: 独自404/500ページ | #90（既存#103が参照） | [404](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/public/404.html)・[500](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/public/500.html)、[error_pages spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/requests/error_pages_spec.rb)。意図的live500は行わない | コード/Request証拠あり／公開エラー画面の再確認は未実施 |
| 開発6: モデルとDBのvalidation | [#98](issue98_model_spec_audit.md)、db/schema.rb | #98モデル別表・Database agreement。NOT NULL/unique/FKとモデル側検証の区別、追加台帳差分は後段A3 | 限定証拠あり／最終schema照合待ち |
| 開発7: メッセージ表示 | [#94](issue94_japanese_errors.md)、[日本語エラーSystem](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/japanese_error_layout_spec.rb)、#95 | #95参照のJapanese error layout、authentication_ui、各保存/失敗画面。通知全種類の網羅は未確定 | 限定証拠あり／最終確認待ち |
| 開発8: 利用中に例外が発生しない | #99、#51の主要フローと障害対応 | 基準main CIは上記。主要フロー実機・公開環境チェックは未実施。ローカル成功だけで例外なしとはしない | 合成主要フロー証拠あり／公開主要フロー未検証 |
| 開発9: seedで各テーブルの初期データをそれぞれ5件以上 | [#92](issue92_safe_demo_seed.md)、[#93](issue93_production_demo.md)、明示的demo seed | #93 Technical acceptance: 12業務表各5件以上・正規PDF10添付。全物理表5件の証明ではない。A1参照 | 限定証拠あり／最終棚卸し・適用判断記録待ち |
| 開発10: CRUD機能 | [#97 CRUD表](issue97_crud_system_audit.md) | direct/indirect CRUDと機能なしを区別したモデル別表。Chrome、Request/Serviceを区別。A2参照 | 限定証拠あり／最終機能照合待ち |
| デザイン1: 分かりやすいページタイトル・説明 | #95全HTML画面title | #95の23画面・27状態・320/390/768/1280px、期待exact title/path/h1 | 限定証拠あり／最終照合待ち |
| デザイン2: 非技術者にも分かる案内 | #95見出し・操作案内・空状態 | #95実ビュー/画像照合。実際の教師/生徒によるユーザビリティ試験は未実施 | 限定証拠あり／最終文言確認待ち |
| デザイン3: 日本語表示・i18n | #94、#98日本語default locale統合記録 | #95エラー画面再利用、#98日本語locale下のmodel/service検証記録。最終翻訳漏れを確認 | 限定証拠あり／最終照合待ち |
| デザイン4: エラー表示でレイアウトが崩れない | #94 Japanese error layout、#95 | #95に長文/複数入力エラー参照あり。全エラー×全画面×4幅の総当たりではない | 限定証拠あり／最終照合待ち |
| デザイン5: 未完成・初期状態のデザインがない | #95全画面監査、#101/#102設計資料 | #95画像3種と空状態。最終版の取り残し・資料差分を確認 | 最終UI・資料確認待ち |
| デザイン6: 要素が隠れていない | #95画面別表 | #95可視input/select/button寸法、PDF・footer等既存回帰。未確認状態は同文書参照 | 限定証拠あり／最終照合待ち |
| デザイン7: はみ出しがない | #95画面幅チェック | #95ページ全体の横幅・4幅画像。成績表の意図した内部scrollとdocument overflowを区別 | 限定証拠あり／最終照合待ち |
| デザイン8: header/footer（画面による例外可） | #91footer、#95画面監査 | #95既存footer/PDF回帰。画面別の除外・理由を最終確認 | 限定証拠あり／最終照合待ち |
| デザイン9: header/footerの上下配置が適切 | #95全画面監査 | [390pxフロー](issue95-evidence/flow-390.jpg)、[tablet/desktop](issue95-evidence/tablet-desktop.jpg)。タブレット実機は未検証 | 限定証拠あり／最終照合待ち |
| デザイン10: 適切なリンク名 | #95リンク名・戻る導線 | #95実ビュー/画像、成績→答案→保存後/戻り先。最終文言と遷移図を同期 | 限定証拠あり／最終照合待ち |
| デザイン11: 適切なボタン名 | #95ボタン名・操作チェック | #95可視button寸法/画面画像、既存フォーム操作回帰。最終文言確認 | 限定証拠あり／最終照合待ち |
| デザイン12: 明確な入力ラベル・placeholder | #95 label/placeholder照合 | #95実ビュー/画像、フォームinput/select寸法。placeholderだけをlabelの証明とはしない | 限定証拠あり／最終照合待ち |
| 画面遷移1: rootの設定 | [routes](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/config/routes.rb)、[home spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/requests/home_spec.rb) | #95 `home` exact path、基準routesのrootを照合済み／公開rootは古い観測で404 | 限定証拠あり／最終照合待ち |
| 画面遷移2: 初回にトップを表示 | #89トップ、#95未ログイン画面 | #95 `/`。新規未認証セッションで公開URLからの初回遷移を確認 | 公開初回遷移未検証 |
| 画面遷移3: ログイン後に適切な画面へ | [#96](issue96_authentication_system_audit.md) | `spec/system/footer_spec.rb:35` の教師/生徒/管理者loginと到達先（#96記録） | 限定証拠あり／最終照合待ち |
| 画面遷移4: 不適切・不要な遷移がない | #95戻り条件、#96認証境界、#99 | #95答案のcontext保持・不正context拒否、#96logout/history/切替。最終図・公開動作と照合 | 限定証拠あり／最終照合待ち |
| 機能1: ログイン機能 | #96教師/生徒/管理者認証 | `spec/system/authentication_access_spec.rb` と既存 [footer_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/footer_spec.rb)。成功/失敗/切替 | 限定証拠あり／最終照合待ち |
| 機能2: 管理者機能 | #96管理画面、#97アカウント操作 | `spec/system/admin_account_management_spec.rb`、#97 account CRUD。管理範囲は学校境界を保持 | 限定証拠あり／最終照合待ち |
| 機能3: 管理者・一般ユーザーのゲスト | [#93](issue93_production_demo.md)、[guest controller](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/controllers/guest_sessions_controller.rb)、#96 | `spec/system/guest_browsing_spec.rb:31` はrack_test、`:57` はChrome履歴。#93隔離local HTTPSは公開Chrome検証ではない | 技術証拠あり／公開ゲスト検証未完了 |
| 機能4: controllerで管理者アクセス制限 | [#96](issue96_authentication_system_audit.md)、[admin base controller](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/controllers/admin/base_controller.rb) | [authentication_access_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/authentication_access_spec.rb): 普通roleのadmin URL/PATCH拒否、学校境界、変更なし確認 | 限定証拠あり／最終照合待ち |
| 機能5: 一般ユーザーに管理者操作を表示しない | #96教師/生徒の管理リンク・form action不在 | [authentication_access_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/authentication_access_spec.rb) の画面非表示とcontroller拒否を別々に検証 | 限定証拠あり／最終照合待ち |
| System Spec1: ログイン機能のテスト | #96 role×operation表 | [footer_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/footer_spec.rb)、[authentication_access_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/authentication_access_spec.rb)（Chrome）、guestのdriver区別は機能3参照 | 既存証拠＋基準main全suite成功／提出headは要更新 |
| System Spec2: 各モデルのCRUD機能のテスト | #97モデル別C/R/U/D表 | `spec/system/assignment_crud_spec.rb`、[quiz_grading_workflow_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/quiz_grading_workflow_spec.rb)、[student_pdf_preview_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/student_pdf_preview_spec.rb) 等。Request/Serviceのみのセルは別分類。A2参照 | 限定証拠あり／最終モデル・機能照合待ち |
| System Spec3: アクセス制限のテスト | #96拒否/許可表 | [authentication_access_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/authentication_access_spec.rb) の未認証・role・学校・作成者・配信範囲拒否と正例。Cancancan注記はA4参照 | 既存証拠＋基準main全suite成功／提出headは要更新 |
| System Spec4: 全System Specが成功 | 基準mainの[CI test job](https://github.com/arduino0420/quickflow/actions/runs/39876600200) | 過去の関連成功・失敗/診断は#95/#96/#97に限定記録。基準suiteは全Systemを含んで成功。区分単独の件数は本文から推定しない | 基準main全suite成功／最終提出head・公開動作は未確認 |
| Model Spec1: すべての宣言済みvalidationのテスト | #98モデル別validation表、追加台帳差分 | `spec/models/*` の対応表、#47追加モデルを最終mainで再照合。A3参照 | 限定証拠あり／最終validation棚卸し待ち |
| Model Spec2: 使用scopeのテスト | #98 explicit scope/enum記録 | [models/assignment_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/models/assignment_spec.rb): `distributed_to_school`、[models/grading_result_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/models/grading_result_spec.rb): `pending_review`。基準sourceの明示scopeはこの2件。enum生成scopeは既存mapping検証を参照 | 限定証拠あり／最終scope棚卸し待ち |
| Model Spec3: 成功・失敗の両方をテスト | #98各行の正例/負例 | 空・境界・重複・別学校/クラス・更新拒否と状態不変・正例。追加台帳の正例/負例は最終確認 | 限定証拠あり／最終照合待ち |
| Model Spec4: 全Model Specが成功 | 基準mainの[CI test job](https://github.com/arduino0420/quickflow/actions/runs/39876600200) | #98のmodel+PasswordPolicy393例/0失敗は過去の限定範囲。基準suiteは全Modelを含んで成功。区分単独の件数は本文から推定しない | 基準main全suite成功／最終提出head・公開動作は未確認 |

### 適用判断（要件本文を変更しない）

- **A1 / 開発9:** #92/#93の技術完了と公開配備を分ける。通常 `db:seed` ではデモを生成しない。明示的・隔離されたseedと12業務表各5件以上の証拠を用いる。認証counter、queue/cache/cable、variant、Rails metadata、内部要求台帳は真正な処理の運用状態であり、架空履歴を作らない。#47要求台帳は合成教材で0件/pointer nilとする運用理由を基準schemaとmanifest方針に結び付ける。**「各テーブル」の要件は削除せず、全物理表5件達成とも公式免除とも記載しない。** 基準sourceはprimary17表（14アプリ＋3ActiveStorage）、具象ApplicationRecord14モデル。別DBはcache1・queue13・cable1表。12初期業務表、認証counter、要求台帳、3添付表を区別し、全物理表5件の達成とはしない。要求台帳0/pointer nil、Submission claim3列nilは合成デモの実方針で、旧manifestは自動rebaselineしない。
- **A2 / 開発10・System2:** #97の直接/間接操作、機能なし、運用CLI、System/Request/Serviceを区別する。「各モデルのCRUD機能」を「対象モデルのみ」に書き換えない。既存機能のないTeacher削除や内部モデルの公開CRUDをチェック欄のために増設しない。既存実装に即した根拠を記録し、全モデル完全CRUDや公式免除を主張しない。#47等の後続モデルは最終mainで表の差分を確認する。
- **A3 / 開発6・Model1–3:** #98は当時のモデル/schemaの証拠。全ての数値/書式/enum/学校整合をDB CHECKでも重複実装しているとは主張しない。validation/scopeがない内部モデルと抽象基底はその実装事実とサービス証拠を示す。追加台帳は[QuestionGenerationRequest](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/models/question_generation_request.rb)のpresence/state/failure_code/input一意性・belongs_toと[Assignment](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/models/assignment.rb)のpointer所属検証を、[lifecycle spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/services/question_generation_lifecycle_spec.rb)、[job spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/jobs/question_generation_job_spec.rb)、[fencing spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/jobs/processing_claim_fencing_spec.rb)で補足。専用Model Specファイルが全14モデルにあるという主張はしない。旧#98の棚卸しに対する追加行として、未証明の宣言単位があればM1/M3の要確認を保持する。
- **A4 / System3:** Cancancan固有テストが任意であることは、アクセス制限テスト全般の免除ではない。#96の実controllerを通る許可/拒否証拠を残す。
- **A5 / デザイン8:** header/footerの画面別例外は原文で許容されるが、各画面の実装と理由を記録する。その他のデザイン項目まで除外しない。

### 配備・提出・学校受入の残件

上記コード/CIの照合と公開環境を分ける。配備image digest・実SHA・DB/mount/worker・TLS/Cookie・主要フロー・隔離ゲストURLは未検証。実タブレット/学校利用者の受入も未実施。下記#99合成QAを取り込んだが、公開実環境の確認とは区別する。

### #99 合成フローの追加証拠（2026-10-23）

別QAタスクから受領したZIP version3（SHA-256 `16d4b368fb8a5c37fce8e11553c7d2a9ccab33816b4642e6109dc4b019be8bf6`）を検証し、選択画像だけを[issue99-evidence](issue99-evidence/)へ収録した。private log・credential・ローカルパス・内部taskメモは収録しない。本タスクが再実行した証拠ではない。対象は[exact02a8237](https://github.com/arduino0420/quickflow/commit/02a823714eb5d627927318ddf544215117b6a38a)、アプリ/config/schema/lockは9704b30と差分なし。PR23は除外。

Ruby4.0.6/Rails8.1.4/PG18.6、macOS x86_64、Chrome155.0.8059.86/ChromeDriver155.0.8059.84、専用loopback DB/storage、架空PDF/アカウント、typed AI doublesで検証。実AIは呼ばず、全suite再実行なし。対象14 unique examplesが成功。全試行では17 executions中14成功・3失敗で、初回2失敗はcheckout-local qpdf不足による503、前提を整えて同じ2例が成功した。残るSelenium失敗は下段のとおり保持する。親確認のmain CI2034/0とは別の限定検証である。

| 確認範囲 | 実在するsourceと成功証拠 | 制限 |
| --- | --- | --- |
| 教師配信→読取/採点→教師修正→生徒結果→実Excel download | [quiz_grading_workflow_spec](https://github.com/arduino0420/quickflow/blob/02a823714eb5d627927318ddf544215117b6a38a/spec/system/quiz_grading_workflow_spec.rb)、[配信](issue99-evidence/01-teacher-distribution.png)、[結果5点](issue99-evidence/03-student-reviewed-result.png)、[成績/Excel](issue99-evidence/04-teacher-grades-excel.png)。未提出blankと採点完了0、訂正後5を区別 | 実AI数学精度や本番performanceの証明ではない |
| 手書き/消しゴム・保存/再読込・offline retry/leave警告・複数page提出 | [student_pdf_preview_spec](https://github.com/arduino0420/quickflow/blob/02a823714eb5d627927318ddf544215117b6a38a/spec/system/student_pdf_preview_spec.rb)、[保存筆跡](issue99-evidence/02-student-saved-handwriting.png)。座標/消去位置/元text/3pageを確認 | 実端末pen、全browser、実回線断は未確認 |
| AI失敗/復旧・二重提出/古いform・認可拒否 | 上記workflowと[authentication_access_spec](https://github.com/arduino0420/quickflow/blob/02a823714eb5d627927318ddf544215117b6a38a/spec/system/authentication_access_spec.rb)。stub outageでfailed/結果なし、既存recovery flag off/on、古いformによる置換拒否・既存PDF保持、学校/teacher/student境界を確認 | 専用の時限AI遅延測定・実provider障害ではない |
| 管理者password resetとfilter保持 | [admin_account_management_spec](https://github.com/arduino0420/quickflow/blob/02a823714eb5d627927318ddf544215117b6a38a/spec/system/admin_account_management_spec.rb)、[完了一覧](issue99-evidence/07-admin-account-management.png)。2対象の変更後passwordを実認証確認 | 架空専用dataのみ |
| 管理者番号変更・cancel・未使用生徒削除 | 別の1回の標準Chrome手動CUA確認。[preview](issue99-evidence/09-admin-attendance-preview.jpg)時点ではDB不変、確定後1→3、削除cancelでは保持、[削除後](issue99-evidence/11-admin-confirmed-deletion.jpg)は指定架空生徒1人だけ不在。PATCH/DELETE各1回303、他data保持を読取照合 | 自動例をgreenへ読み替えない。下記instrumentation限界を保持 |
| 教師iframeの架空PDF描画 | 1回の標準Chrome手動確認、[画像12](issue99-evidence/12-teacher-native-pdf-rendered.jpg)。200/application-pdf/inline、4698byte、fixture/response同一SHA256 `530f34ed5ced53574d5beda84604736f1137030af5d22bfa3872050a0a21b3a0`。1pageの矩形/斜線がfixtureと一致 | 全pageの視覚監査ではない。旧headless画像05の空欄原因は不明で成功例に使わない |
| Excel順序・未提出と0点・card表示 | [classroom_grade_exporter_spec](https://github.com/arduino0420/quickflow/blob/02a823714eb5d627927318ddf544215117b6a38a/spec/services/classroom_grade_exporter_spec.rb)、[assignment_exports_spec](https://github.com/arduino0420/quickflow/blob/02a823714eb5d627927318ddf544215117b6a38a/spec/requests/assignment_exports_spec.rb)。出席順/欠番/40行、blankと数値を確認。task限定card確認は未提出white/bold・提出済gray/normal | 複数classを組み合わせた順序は今回新規検証していない |

保持する自動化限界：`admin_account_management_spec.rb`の番号変更→削除例はChromeDriver inspector `-32000: Node with given id does not belong to the document`。preview POST200後、PATCH/DELETE前に観測が失敗した。原因をアプリ不良またはreadiness不足と断定しない。上記手動確認は実際の合成フローを補足するが、元のSelenium例成功や根因解決を意味しない。追加の自動green rerunが必要なら別途診断/レビューする。この記録から#99をcloseしない。

### 設計資料・WBSの確認済み状態（2026-10-23）

- [PR124](https://github.com/arduino0420/quickflow/pull/124)をmain `02a823714eb5d627927318ddf544215117b6a38a`へ統合済み。[main CI39881045679](https://github.com/arduino0420/quickflow/actions/runs/39881045679)成功は親タスク確認。[図・差分説明](../design/README.md)、[全属性/制約](../design/schema_reference.md)、[検証記録](../design/validation.json)を本ブランチへ通常統合した。アプリコード基準9704b30とschema/routesは変わらない。
- 親タスクの原本更新・Mac視覚確認により、[要件/カタログ/テーブル定義Sheet](https://docs.google.com/spreadsheets/d/1G-4Q3SS79nOKc3IJGaaYNftkwM0XktCnIgPAiMZ-1ug/edit)はコード9704b30に同期し、更新範囲の可読性を確認。[Whimsical](https://whimsical.com/Lj1FAP2VsasTMNMjFAfDb4)の17フレームも確認済み。この文書タスクから外部書込や共有権限の拡大はしていない。図文書の原本未更新という記述は図作成時点の範囲で、原本の後続確認はこの段落で区別する。
- 親タスクにより[WBS](https://docs.google.com/spreadsheets/d/14l9J34G3nBm1N_H-dbQBEf9kfags0VL9w_DPs9JY-vs/edit)のmilestone更新済み。数式/日付は変更していない。本タスクはWBSを追加編集しない。

### #102 提出説明の準備（送信していない）

技術的整合と差分の根拠は上記原本・[図の説明](../design/README.md)を参照する。当初の合格済み要件の内容・承認経緯は原本Sheetが一次資料であり、このリポジトリだけから推測しない。

| 差分 | 現行実装・説明する理由と証拠 |
| --- | --- |
| 旧図の公開signup/初期設定/rails_admin | 役割別ログインと自校の管理者管理へ更新。学校/権限境界を実装に合わせる。#96/#97の認証/CRUD表 |
| 教師/クラス関係・学校・管理者 | teacher_classroomsの担当関係、legacy classroom teacher FK、管理者/認証制限を区別。schema_referenceのNULL/Unique/FKと一致 |
| 生徒の答案 | PDF手書き・自動保存・正式提出・結果と復帰導線を図へ反映。保存と提出を区別。#95/#97、実際のroutes/view |
| 配信/採点/出力 | 正答生成台帳・current pointer、nullable fenced claim、教師の最終判定、Excelを反映。#47/#46/#49とSystem証拠 |
| 閲覧専用ゲスト | 隔離された架空データの閲覧のみ。公開済み/手書き/AI体験と表現しない。#93 |

通知用本文案：要件・カタログ・テーブル定義、ER/画面遷移、ワイヤーフレームをコード9704b30に照合しました。役割別認証/管理者管理、担当クラス、PDF手書き/自動保存/提出、正答生成要求/claim、教師判定/Excel、閲覧専用ゲストの差分を上記資料へ整理しています。公開配備・復元実証・実端末/学校受入は未完了です。修正版資料の再投稿と変更通知は本人が別途実施します。

#102の実DoDは現行資料の整合、差分/対象外/今後の課題、通知内容の準備であり、**実送信を技術資料のclosure条件へ追加しない**。上記artifact/link確認と親レビュー後に#102の完了判断材料とする。このタスクはIssueをcloseしない。

#101/#103に残る本人のDPro再投稿・メンター通知・提出URL入力と完了画面確認は未完了。要件定義課題合格の本人確認も別。#51/#99/#101/#103/#88は配備/公開確認や人間の手続きが残り、文書や技術Issue完了だけでcloseしない。#105の実DoDは初学者ガイドと短時間の作品資料、実装との差異/機密露出なし。READMEの3ロール操作/失敗対処・選択済み合成画像と、日本語5枚の[編集PPTX](../presentation/quickflow-overview-ja.pptx)・[閲覧PDF](../presentation/quickflow-overview-ja.pdf)を収録。親タスクが最終pixelと構造/layoutを確認済み、本タスクも5枚/話者ノート/公開文言/秘密値不在を照合した。PDFは画像ベースで検索/編集不可、PPTXは編集可能。実導入効果/他ICTより優位という実証や利用者ヒアリングはしていない。#105はこの成果物と親レビューで完了判断できる資料として用意し、本タスクからcloseしない。
