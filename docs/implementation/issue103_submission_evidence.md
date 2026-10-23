# #103 必須39項目の証跡対応（提出未完了）

39行表は認証済み原文の確認記録・既存草案とcode/testを照合したもの。guestの該当1文は2026-10-23に実行担当も認証済み原文で確認した。課題全体の再読や公式合格判定とは区別し、追加メンター解釈承認をゲートにしない。


### 原文との対応・証拠の基準

原文: [DPro curriculum 3027](https://diver.diveintocode.jp/curriculums/3027)。認証済み原文の確認記録は2026-10-22（原文更新日時2026-09-28 06:48 JST）。下表の要件欄は受領した39項目の**意味を保持した要約**であり、逐語引用ではない。番号はカテゴリ内の順序。適用判断を要件本文に混ぜず後段へ分離した。本草案は原文確認記録と既存証拠文書を基にした二次照合である。

最終配備/試験基準: [main1adb1530](https://github.com/arduino0420/quickflow/commit/1adb1530bfde72b1e9c1c9bce711b6a015ece062)、[CI39942867222](https://github.com/arduino0420/quickflow/actions/runs/39942867222)全4ジョブ成功、RSpec2,039例/失敗0（System/Modelを含む全suite、区分単独件数ではない）。Ruby4.0.6/Rails8.1.4。表の固定source9704b30は既存監査時の基準。047ba388からの最終アプリ差分はトップ/guest導線・採点待機CSS/文言の5ファイルで、models/jobs/schema/認証/配信・採点処理は変更なし。最新のhome/guest導線は[PR130](https://github.com/arduino0420/quickflow/pull/130)、[PR131](https://github.com/arduino0420/quickflow/pull/131)、[PR132](https://github.com/arduino0420/quickflow/pull/132)と下記公開確認を参照。PR23は未merge close（branch/history保持、互換性完了の主張なし）。今回のPRは文書のみで、稼働imageに文書commitは含まれない。既存証拠と今回の実測を統合し、限定証拠を全操作OKへ読み替えない。

状態「実装・既存試験証拠あり」は指定sourceと過去監査/上記CIの範囲。**merged / deployed / submitted / 学校での受入**を別々に扱う。全39項目合格や公開実機検証済みとはしない。画像は架空データのChrome証拠（#95と下記#99）であり実端末・実学校の受入証拠ではない。

| 要件 | 対応する実装・資料 | テストや画面の証拠 | 状態 |
| --- | --- | --- | --- |
| 開発1: Ruby on Railsを使用 | [README](../../README.md)、[Gemfile.lock](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/Gemfile.lock) Rails8.1.4 | [Ruby4.0.6](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/.ruby-version)、上記CIのbundle/setupとsuite成功 | source/CI・配備runtime確認済み |
| 開発2: HerokuまたはAWS EC2へデプロイ | #51/#99配備runbook、AWS方針 | [runbook](issue51_predeployment_runbook.md)。下記「本番の追加証拠」で実EC2稼働・image・公開TLSを確認 | 配備・公開guest導線確認済み／提出は本人未実施 |
| 開発3: トップページがある | [home view](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/views/home/index.html.erb)、#89/#95 | [画面監査](issue95_screen_audit.md): `home`、4幅Chrome・title/h1/exact path | 既存試験・最新公開Chrome確認済み |
| 開発4: トップでサービス・コンセプト・機能が分かる | [home view](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/views/home/index.html.erb)、[home spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/home_spec.rb) | #95 `home`と[320px一覧](issue95-evidence/overview-320.jpg)。元の説明2文を残した最新公開Chrome画面と照合済み | 実装/公開本文確認済み／学校受入未判定 |
| 開発5: 独自404/500ページ | #90（既存#103が参照） | [404](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/public/404.html)・[500](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/public/500.html)、[error_pages spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/requests/error_pages_spec.rb)。意図的live500は行わない | コード/Request証拠あり／公開エラー画面の再確認は未実施 |
| 開発6: モデルとDBのvalidation | [#98](issue98_model_spec_audit.md)、db/schema.rb | #98モデル別表・Database agreement。NOT NULL/unique/FKとモデル側検証の区別、追加台帳差分は後段A3 | 限定証拠あり／最終schema照合待ち |
| 開発7: メッセージ表示 | [#94](issue94_japanese_errors.md)、[日本語エラーSystem](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/japanese_error_layout_spec.rb)、#95 | #95参照のJapanese error layout、authentication_ui、各保存/失敗画面。通知全種類の網羅は未確定 | 限定証拠あり／最終確認待ち |
| 開発8: 利用中に例外が発生しない | #99、#51の主要フローと障害対応 | 基準main CIは上記。下記の認証付き本番架空フローと所有者の実AI成功報告を分離して参照。全操作で例外が起きない保証ではない | 合成・本番限定フローと公開guest確認済み／全操作保証ではない |
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
| 画面遷移1: rootの設定 | [routes](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/config/routes.rb)、[home spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/requests/home_spec.rb) | #95 `home` exact path、基準routesのrootを照合済み／2026-10-23配備後の公開root200（古い404は履歴） | 限定証拠あり／最終照合待ち |
| 画面遷移2: 初回にトップを表示 | #89トップ、#95未ログイン画面 | #95 `/`。新規未認証セッションで公開URLからの初回遷移を確認 | 公開初回遷移未検証 |
| 画面遷移3: ログイン後に適切な画面へ | [#96](issue96_authentication_system_audit.md) | `spec/system/footer_spec.rb:35` の教師/生徒/管理者loginと到達先（#96記録） | 限定証拠あり／最終照合待ち |
| 画面遷移4: 不適切・不要な遷移がない | #95戻り条件、#96認証境界、#99 | #95答案のcontext保持・不正context拒否、#96logout/history/切替。最終図・公開動作と照合 | 限定証拠あり／最終照合待ち |
| 機能1: ログイン機能 | #96教師/生徒/管理者認証 | `spec/system/authentication_access_spec.rb` と既存 [footer_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/footer_spec.rb)。成功/失敗/切替 | 限定証拠あり／最終照合待ち |
| 機能2: 管理者機能 | #96管理画面、#97アカウント操作 | `spec/system/admin_account_management_spec.rb`、#97 account CRUD。管理範囲は学校境界を保持 | 限定証拠あり／最終照合待ち |
| 機能3: 管理者・一般ユーザーのゲスト | [#93](issue93_production_demo.md)、[guest controller](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/controllers/guest_sessions_controller.rb)、#96 | `spec/system/guest_browsing_spec.rb`の既存証拠と下記2026-10-23公開3役Chrome/PDF確認。local証拠とlive観測を区別 | 公開3役閲覧確認済み／read-onlyの公式受入は学校判定 |
| 機能4: controllerで管理者アクセス制限 | [#96](issue96_authentication_system_audit.md)、[admin base controller](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/controllers/admin/base_controller.rb) | [authentication_access_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/authentication_access_spec.rb): 普通roleのadmin URL/PATCH拒否、学校境界、変更なし確認 | 限定証拠あり／最終照合待ち |
| 機能5: 一般ユーザーに管理者操作を表示しない | #96教師/生徒の管理リンク・form action不在 | [authentication_access_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/authentication_access_spec.rb) の画面非表示とcontroller拒否を別々に検証 | 限定証拠あり／最終照合待ち |
| System Spec1: ログイン機能のテスト | #96 role×operation表 | [footer_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/footer_spec.rb)、[authentication_access_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/authentication_access_spec.rb)（Chrome）、guestのdriver区別は機能3参照 | 既存証拠＋最終配備1adb1530全suite成功／提出対象変更時は再確認 |
| System Spec2: 各モデルのCRUD機能のテスト | #97モデル別C/R/U/D表 | `spec/system/assignment_crud_spec.rb`、[quiz_grading_workflow_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/quiz_grading_workflow_spec.rb)、[student_pdf_preview_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/student_pdf_preview_spec.rb) 等。Request/Serviceのみのセルは別分類。A2参照 | 限定証拠あり／最終モデル・機能照合待ち |
| System Spec3: アクセス制限のテスト | #96拒否/許可表 | [authentication_access_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/authentication_access_spec.rb) の未認証・role・学校・作成者・配信範囲拒否と正例。Cancancan注記はA4参照 | 既存証拠＋最終配備1adb1530全suite成功／提出対象変更時は再確認 |
| System Spec4: 全System Specが成功 | 基準mainの[CI test job](https://github.com/arduino0420/quickflow/actions/runs/39942867222) | 過去の関連成功・失敗/診断は#95/#96/#97に限定記録。基準suiteは全Systemを含んで成功。区分単独の件数は本文から推定しない | 配備1adb1530全suite成功／公開guestを含む限定証拠は下記 |
| Model Spec1: すべての宣言済みvalidationのテスト | #98モデル別validation表、追加台帳差分 | `spec/models/*` の対応表、#47追加モデルを最終mainで再照合。A3参照 | 限定証拠あり／最終validation棚卸し待ち |
| Model Spec2: 使用scopeのテスト | #98 explicit scope/enum記録 | [models/assignment_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/models/assignment_spec.rb): `distributed_to_school`、[models/grading_result_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/models/grading_result_spec.rb): `pending_review`。基準sourceの明示scopeはこの2件。enum生成scopeは既存mapping検証を参照 | 限定証拠あり／最終scope棚卸し待ち |
| Model Spec3: 成功・失敗の両方をテスト | #98各行の正例/負例 | 空・境界・重複・別学校/クラス・更新拒否と状態不変・正例。追加台帳の正例/負例は最終確認 | 限定証拠あり／最終照合待ち |
| Model Spec4: 全Model Specが成功 | 基準mainの[CI test job](https://github.com/arduino0420/quickflow/actions/runs/39942867222) | #98のmodel+PasswordPolicy393例/0失敗は過去の限定範囲。基準suiteは全Modelを含んで成功。区分単独の件数は本文から推定しない | 配備1adb1530全suite成功／公開guestを含む限定証拠は下記 |

### 適用判断（要件本文を変更しない）

- **A1 / 開発9:** #92/#93の技術完了と公開配備を分ける。通常 `db:seed` ではデモを生成しない。明示的・隔離されたseedと12業務表各5件以上の証拠を用いる。認証counter、queue/cache/cable、variant、Rails metadata、内部要求台帳は真正な処理の運用状態であり、架空履歴を作らない。#47要求台帳は合成教材で0件/pointer nilとする運用理由を基準schemaとmanifest方針に結び付ける。**「各テーブル」の要件は削除せず、全物理表5件達成とも公式免除とも記載しない。** 基準sourceはprimary17表（14アプリ＋3ActiveStorage）、具象ApplicationRecord14モデル。別DBはcache1・queue13・cable1表。12初期業務表、認証counter、要求台帳、3添付表を区別し、全物理表5件の達成とはしない。要求台帳0/pointer nil、Submission claim3列nilは合成デモの実方針で、旧manifestは自動rebaselineしない。
- **A2 / 開発10・System2:** #97の直接/間接操作、機能なし、運用CLI、System/Request/Serviceを区別する。「各モデルのCRUD機能」を「対象モデルのみ」に書き換えない。既存機能のないTeacher削除や内部モデルの公開CRUDをチェック欄のために増設しない。既存実装に即した根拠を記録し、全モデル完全CRUDや公式免除を主張しない。#47等の後続モデルは最終mainで表の差分を確認する。
- **A3 / 開発6・Model1–3:** #98は当時のモデル/schemaの証拠。全ての数値/書式/enum/学校整合をDB CHECKでも重複実装しているとは主張しない。validation/scopeがない内部モデルと抽象基底はその実装事実とサービス証拠を示す。追加台帳は[QuestionGenerationRequest](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/models/question_generation_request.rb)のpresence/state/failure_code/input一意性・belongs_toと[Assignment](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/models/assignment.rb)のpointer所属検証を、[lifecycle spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/services/question_generation_lifecycle_spec.rb)、[job spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/jobs/question_generation_job_spec.rb)、[fencing spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/jobs/processing_claim_fencing_spec.rb)で補足。専用Model Specファイルが全14モデルにあるという主張はしない。旧#98の棚卸しに対する追加行として、未証明の宣言単位があればM1/M3の要確認を保持する。
- **A4 / System3:** Cancancan固有テストが任意であることは、アクセス制限テスト全般の免除ではない。#96の実controllerを通る許可/拒否証拠を残す。
- **A5 / デザイン8:** header/footerの画面別例外は原文で許容されるが、各画面の実装と理由を記録する。その他のデザイン項目まで除外しない。

### 配備・提出・学校受入の残件

配備identity/runtime/DB/storage/worker/TLS/Cookieと限定本番主要フローは下記で確認済み。公開guest評価導線は確認済み。本人の要件定義合格確認、最終UI差分の設計原本への反映確認、設計差分再投稿/通知、最終提出/完了画面は残る。実タブレット/学校利用者の受入は未実施で、原文にない追加の提出停止条件にはしない。seed/内部CRUDの適用根拠と未証明の宣言単位は保持し、全39合格を宣言しない。

### 本番の追加証拠（2026-10-23）

| 情報源 | 確認済み範囲 | 限界 |
| --- | --- | --- |
| 配備担当の実行記録（#51/#99既存配備欄） | source047ba388/image digest、Ruby4.0.6/Rails8.1.4/qpdf12.4.2、migration20本/最新20261022110000、volume/既存値/PDF保持、整合backupと隔離復元、約40秒maintenance、TLS/root/up/3login、Secure Cookie、worker heartbeat | 同一server backupは災害対策の証明ではない。HSTSなし。手動頻度/backup目安/保持方針は[runbook](issue51_predeployment_runbook.md)のとおり所有者合意済み、詳細閾値/Host/HSTS判断は残件 |
| 本番の専用架空データ・実行担当のUI確認 | 3role login/logout、学校限定admin一覧、教師からadmin拒否、教師判定0→5、生徒結果5/正解、Excel実download（数値5/未提出blank）、教材PDF、admin編集preview/cancel保持 | 実ユーザーdataの閲覧/変更/削除なし。adminの確定更新/削除はこの本番検証で実行しない。ローカルの別証拠と区別 |
| 通常Chromeの追加確認 | [教師iframe描画](issue99-evidence/production-chrome-teacher-pdf.jpg)。保存PUT200/DB操作1件を確認し、Chromeで「保存済み」を待って既存筆跡表示→1回reload→「保存済み」→[同じ線の復元](issue99-evidence/production-chrome-draft-restored.jpg) | 初回の「保存失敗」は復元完了観測不足で撤回。IAB黒PDFの内部原因は未確定。全PDF/全browser/実端末の保証ではない。追加筆跡/正式提出は不要で未実行 |
| 所有者の報告（親から受領、担当の独立観測ではない） | 通常UXに問題なし。実AIによる配信・提出・採点も実施し、問題なし | 使用データ/全結果/料金/精度を担当が監査したものではない。担当自身のAI実行や有料テストの成功とは記載しない |

確認用データは明示して保持。専用教師と未提出生徒のみ承認済みpassword reset後にChrome確認し、session終了/一時secret破棄。credential・内部ID・私有server pathを本文や画像に掲載しない。実装修正/再配備は不要だった。#99の公開記録には本追補の反映がまだ必要であり、未投稿の追記にURLがあるとは扱わない。

公開guestは[runbookの実構成](issue51_predeployment_runbook.md#公開guest評価導線同一server架空データ専用)のとおり確認済み。個別架空アカウントによる学校本番の試験と、独立guestの証拠を混ぜない。原文の管理者/一般ユーザーguestは必須であるが、read-only十分との明記はなく、別serverも要件ではない。工学的最小解釈と学校の合格判定を区別する。

### 最新の公開切替・guest・表示確認（2026-10-23）

- 通常/guestのsourceは上記1adb1530、app image `sha256:77c3ea0a189c6ff41ff4d61d87c177df8894e00d59c35a2a49d205f07934863a`。[通常app](https://13-231-93-159.sslip.io/)から[guest入口](https://qfd-4c18332acca47671.13-231-93-159.sslip.io/)へ遷移を確認。12:45:27–12:46:42 UTCの約75秒maintenanceで、queue/claim静止3回→旧worker正常停止→新web/worker→再開。DB移行・seed・データrollbackなし。migration/同一storage mount継続、旧image/backup保持。詳細は[運用記録](issue51_predeployment_runbook.md#最新状態2026-10-23配備後の確認済み記録)。
- 実行担当の通常Chrome確認: 大きいロゴ、元の説明2文、教師/生徒/guestの同色・指定順のボタン、既存2login画面とguest遷移。公開CSSは丸1.1rem/移動10px・reduced-motion保持、不要案内除去。実AIを使う採点中状態は再実行せず、過去の24例/失敗0の合成表示証拠と、今回のserved asset/partial確認を区別する。
- 公開guestの3役login/表示/終了、教師と生徒の答案PDFの実描画を通常Chromeで確認。専用架空DB/storage/鍵、readonly業務権限とmanifest、別host/namespace、両段厳密TLS、Origin/他校/書込/転送header拒否、PDF/Excel形式確認を記録。64KiB body制限とupstream接続上限2を維持するが、厳密な同時要求数2ではない。864MiB/1CPU ceiling、0worker/AI、新serverなし。全PDF/全browser/ピーク負荷/実学校受入の証明ではない。
- 通常root/up/3loginとguestは200、通常sessionはSecure/HttpOnly/Lax/Path=/。新Supervisor(fork)/Worker/Dispatcher/Scheduler各1の最近heartbeat、観測時queue5分類/active claim0。通常Caddy設定はmaintenance前と一致、guestは既存Let’s Encrypt account/同意済みtermsを再利用。HSTS未設定・Rails Host強化未追加の監査結果は保持し、課題にない追加必須項目としない。
- 所有者の以前の「通常UX・実AI配信/提出/採点は問題なし」という報告は上表の出典のまま。今回の担当による実AI再試験、全精度検証、卒業合格へ読み替えない。#99のコメント追記は以前のtool target ambiguityによる拒否のまま未投稿で、別routeで再投稿していない。この独立して承認済みのrepo文書更新は、拒否されたコメントの投稿成功とは扱わない。

### #99 合成フローの追加証拠（2026-10-23）

別QAタスクから受領したZIP version3（SHA-256 `16d4b368fb8a5c37fce8e11553c7d2a9ccab33816b4642e6109dc4b019be8bf6`）を検証し、選択画像だけを[issue99-evidence](issue99-evidence/)へ収録した。private log・credential・ローカルパス・内部taskメモは収録しない。本タスクが再実行した証拠ではない。対象は[exact02a8237](https://github.com/arduino0420/quickflow/commit/02a823714eb5d627927318ddf544215117b6a38a)、アプリ/config/schema/lockは9704b30と差分なし。PR23は除外（2026-10-23所有者指示で未merge close、branch/history保持、互換性完了の主張なし）。

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

保持する自動化限界：`admin_account_management_spec.rb`の番号変更→削除例はChromeDriver inspector `-32000: Node with given id does not belong to the document`。preview POST200後、PATCH/DELETE前に観測が失敗した。原因をアプリ不良またはreadiness不足と断定しない。上記手動確認は実際の合成フローを補足するが、元のSelenium例成功や根因解決を意味しない。追加の自動green rerunが必要なら別途診断/レビューする。このローカル記録単独で#99をcloseせず、上記の本番証拠/所有者報告と実DoDを合わせて判断する。

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
| 閲覧専用ゲスト | 同一serverの分離hostで架空データを公開閲覧。手書き/AI体験と表現しない。#93/PR132 |

通知用本文案：要件・カタログ・テーブル定義、ER/画面遷移、ワイヤーフレームをコード9704b30に照合しました。役割別認証/管理者管理、担当クラス、PDF手書き/自動保存/提出、正答生成要求/claim、教師判定/Excel、閲覧専用ゲストの差分を上記資料へ整理しています。現行版の公開配備・復元実証と限定架空UI確認は完了し、実AI成功は所有者報告です。公開guestの3役とPDF描画を確認済みです。実端末/学校受入と実AIの独立再試験は未実施です。修正版資料の再投稿と変更通知は本人が別途実施します。

#102の実DoDは現行資料の整合、差分/対象外/今後の課題、通知内容の準備であり、**実送信を技術資料のclosure条件へ追加しない**。上記artifact/link確認と親レビュー後に#102の完了判断材料とする。このタスクはIssueをcloseしない。

#101/#103に残る本人のDPro再投稿・メンター通知・提出URL入力と完了画面確認は未完了。要件定義課題合格の本人確認も別。#51/#99は実測・最終CIと限定範囲を実DoDに照らして判断し、本人手続きが残る#101/#103/#88はopenを維持する。#105の実DoDは初学者ガイドと短時間の作品資料、実装との差異/機密露出なし。READMEの3ロール操作/失敗対処・選択済み合成画像と、日本語5枚の[編集PPTX](../presentation/quickflow-overview-ja.pptx)・[閲覧PDF](../presentation/quickflow-overview-ja.pdf)を収録。親タスクが最終pixelと構造/layoutを確認済み、本タスクも5枚/話者ノート/公開文言/秘密値不在を照合した。PDFは画像ベースで検索/編集不可、PPTXは編集可能。実導入効果/他ICTより優位という実証や利用者ヒアリングはしていない。#105はこの成果物と親レビューで完了判断できる資料として用意し、本タスクからcloseしない。

### 本人の最小手続き（#101/#103/#88、未実施）

1. 前課題「要件定義」が合格済みか、本人がDProで確認する。
2. 更新済みWhimsical/要件Sheet/ER/画面遷移/差分一覧の最終URLが審査者に閲覧可能か確認する。URL差替え・共有拡大は必要なら別承認。資料整合確認は親の17frame/Sheet同期記録、技術資料#102完了を使い回す。最終1adb1530で変わったトップのロゴ/3ボタン/公開guest導線・採点待機表示は、その後の差分として原本と照合してから再投稿する。この文書更新だけで外部図の最終反映済みとはしない。
3. 変更した要件/ワイヤーフレームの修正版をDPro課題ページへ再投稿し、既存の通知本文を更新してメンターへ変更点を知らせる。送信日時/リンクを本人が記録する。追加の「解釈承認」を必須gateにしない。
4. 確認済みのrepo URL/公開app URL/上記guest URLを提出欄に入力する。guestはパスワード入力不要の役割選択式である。学校本番の実accountやREADME公開secretは使わない。
5. 本人が最終提出し、完了画面/日時を確認する。#101は再投稿/通知記録後、#103/#88は実DoDの提出証拠後に完了判断。提出前に全Issueを閉じるため要件を弱めない。卒業合格/受理は学校側の結果に従い、技術完了と区別する。
