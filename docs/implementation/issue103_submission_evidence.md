# #103 必須39項目の証跡対応（提出は本人報告済み）

39行表は原文確認記録・既存草案とcode/testを照合したもの。2026-10-24に実行担当も認証済み原文の第8節（10/12/4/5/4/4の39項目）、第9節（提出方法）、設計変更時の再投稿/通知の注記を再確認し、要件の意味と対応表を照合した。課題全体の再読や公式合格判定とは区別し、追加メンター解釈承認をゲートにしない。


### 現在の証拠区分と完了条件

- **担当者の技術証拠:** 既存#95/#96/#98の監査と、後続[PR142](https://github.com/arduino0420/quickflow/pull/142)（home/guest表示）、[PR146](https://github.com/arduino0420/quickflow/pull/146)（guest削除ボタン配置）、[PR148](https://github.com/arduino0420/quickflow/pull/148)（答案PDF表示）の限定回帰・レビュー・配備記録を再利用する。PR145/PR152のModel/CRUD補完を含むmain `2e6df7300a57b638971387ff19d6141f054fa95e` の[CI40139691885](https://github.com/arduino0420/quickflow/actions/runs/40139691885)は全4成功・2062例0失敗。今回は新しい画面監査やテストを行っていない。
- **所有者本人の報告:** 要件定義は合格、設計変更連絡・最終提出は完了。通常教師側PDF・通常生徒側の提出済み答案PDFと再読み込みの確認依頼に対し「通常の教師・生徒ともPDF表示に問題なし」と回答。12業務表各5件以上・内部運用表は理由付き除外・架空履歴を作らないseed方針も確認済みと報告。担当者の独立観測や学校の正式卒業合格へ読み替えない。
- **状態欄の読み方:** 旧「最終確認待ち」を、既にある証拠の範囲に置き換えた。具体的な未実装として追加すべき項目は今回の既存証拠照合では特定していないが、未検証や適用判断がゼロという意味ではない。全39行を一律OKにはしない。
- **#103/#88の判断:** 各項目の判定・根拠の記録、本人の提出等報告、配備結果の参照は揃っている。具体的な未実装や追加すべき試験の残件は今回の照合では特定していない。「要確認」として残る下記の適用・検証区分を確認したうえで、既存の完了条件の最終チェックとクローズ判断・操作は所有者が行う。未チェック条件を削除せず、正式な学校判定や全環境の保証へ読み替えない。

### 原文との対応・証拠の基準

原文: [DPro curriculum 3027](https://diver.diveintocode.jp/curriculums/3027)。認証済み原文の確認記録は2026-10-22（原文更新日時2026-09-28 06:48 JST）。下表の要件欄は受領した39項目の**意味を保持した要約**であり、逐語引用ではない。番号はカテゴリ内の順序。適用判断を要件本文に混ぜず後段へ分離した。本草案は原文確認記録と既存証拠文書を基にした二次照合である。

現行配備/試験基準: 通常・guestとも [0812708](https://github.com/arduino0420/quickflow/commit/0812708fcc4d82dca02eb7d9e9c4594716d64e0b)、[main CI40079428699](https://github.com/arduino0420/quickflow/actions/runs/40079428699) 全4成功、2,062例/失敗0。停止は通常85.8秒・guest16.3秒。答案閲覧を既存PDF.jsへ変更し、本番guestで描画完了9回・実画像4場面、3役割・PDF原本一致・Excel・書込拒否・logoutを確認。通常の認証付き本番描画は担当者自身の試験ではなく、ローカル架空通常試験・CIに加え、下記の所有者本人の確認報告を根拠とする。原本タブのChrome内蔵表示は黒画面も観測し、原因・全環境の安定性は未確定。データ・schema・鍵・manifest・network/TLSは維持し、通常の筆記/保存/提出/採点ロジックは変更していない。新しいホーム/guest表示は [PR142](https://github.com/arduino0420/quickflow/pull/142) の変更で、通常・guestへ配備済み。入口の任意説明文は原文の必須指定ではないが、ログイン後の閲覧専用・実AIなし表示とサーバー側制限は保持する。管理者・一般利用者のguest機能は必須であり、read-onlyを公式に十分とする記載は確認していない。原文の各テーブル5件以上・各モデルCRUDのラベルと、以下の工学的適用説明を区別する。

前版の配備/試験履歴: [mainacd22fb9](https://github.com/arduino0420/quickflow/commit/acd22fb9e9f7241c3e434a147edc09f5f3a13ef7)、[CI40027128404](https://github.com/arduino0420/quickflow/actions/runs/40027128404)全4ジョブ成功、RSpec2,049例/失敗0（System/Modelを含む全suite、区分単独件数ではない）。Ruby4.0.6/Rails8.1.4/crass1.0.8。表の固定source9704b30は既存監査時の基準。前版1adb1530からのruntime差分は[PR134の明示的pen/palm処理](https://github.com/arduino0420/quickflow/pull/134)と[PR136のcrass修正](https://github.com/arduino0420/quickflow/pull/136)のみで、DB/schema/保存形式/認証/採点jobは変更なし。[PR135](https://github.com/arduino0420/quickflow/pull/135)は台帳validation8例と設計差分メモ。通常・guestのsource/image/切替時間と検証限界は[配備記録](issue51_predeployment_runbook.md)を参照。前版のChrome確認は履歴として残し、今回のHTTP/配布asset確認や所有者の実AI報告と混ぜない。PR23は未merge close（branch/history保持）。今回の文書commitは稼働imageに含まれない。

状態「実装・既存試験証拠あり」は指定sourceと過去監査/上記CIの範囲。**merged / deployed / submitted / 学校での受入**を別々に扱う。全39項目合格や公開実機検証済みとはしない。画像は架空データのChrome証拠（#95と下記#99）であり実端末・実学校の受入証拠ではない。

| 要件 | 対応する実装・資料 | テストや画面の証拠 | 状態 |
| --- | --- | --- | --- |
| 開発1: Ruby on Railsを使用 | [README](../../README.md)、[Gemfile.lock](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/Gemfile.lock) Rails8.1.4 | [Ruby4.0.6](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/.ruby-version)、上記CIのbundle/setupとsuite成功 | source/CI・配備runtime確認済み |
| 開発2: HerokuまたはAWS EC2へデプロイ | #51/#99配備runbook、AWS方針 | [runbook](issue51_predeployment_runbook.md)。下記「本番の追加証拠」で実EC2稼働・image・公開TLSを確認 | 配備・公開guest導線確認済み／提出済みは本人報告 |
| 開発3: トップページがある | [home view](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/views/home/index.html.erb)、#89/#95 | [画面監査](issue95_screen_audit.md): `home`、4幅Chrome・title/h1/exact path | 既存試験・最新公開Chrome確認済み |
| 開発4: トップでサービス・コンセプト・機能が分かる | [home view](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/views/home/index.html.erb)、[home spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/home_spec.rb) | #95 `home`と[320px一覧](issue95-evidence/overview-320.jpg)。元の説明2文を残した最新公開Chrome画面と照合済み | 実装/公開本文確認済み／学校受入未判定 |
| 開発5: 独自404/500ページ | #90（既存#103が参照） | [404](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/public/404.html)・[500](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/public/500.html)、[error_pages spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/requests/error_pages_spec.rb)。意図的live500は行わない | コード/Request証拠あり／公開エラー画面の再確認は未実施 |
| 開発6: モデルとDBのvalidation | [#98](issue98_model_spec_audit.md)、db/schema.rb | #98モデル別表・Database agreement。NOT NULL/unique/FKとモデル側検証の区別、追加台帳差分は後段A3 | 既存モデル/DB監査＋追加宣言の照合証拠あり（A3） |
| 開発7: メッセージ表示 | [#94](issue94_japanese_errors.md)、[日本語エラーSystem](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/japanese_error_layout_spec.rb)、#95 | #95参照のJapanese error layout、authentication_ui、各保存/失敗画面。通知全種類の網羅は未確定 | 日本語通知・エラーの既存試験証拠あり／全通知の総当たりではない |
| 開発8: 利用中に例外が発生しない | #99、#51の主要フローと障害対応 | 基準main CIは上記。下記の認証付き本番架空フローと所有者の実AI成功報告を分離して参照。全操作で例外が起きない保証ではない | 限定証拠＋pen修正配備済み／Chromebook実機解消・新版認証付き筆記は未確認 |
| 開発9: seedで各テーブルの初期データをそれぞれ5件以上 | [#150全40表・隔離実測](issue150_seed_table_audit.md)、#92/#93 | 12業務表各5件以上MET、blob/attachment各10。所有者が内部運用表を理由付き除外する方針の確認済みを報告。全40物理表5件はNOT METのまま。A1参照 | 確認された業務範囲MET（所有者報告）／全物理表NOT MET |
| 開発10: CRUD機能 | [#97/#151現行14モデル表](issue97_crud_system_audit.md) | 全具象モデルと実装済み直接/親経由CRUD、機能なし・運用処理を照合。生成要求台帳の配信/状態/親削除を補完。全モデル完全CRUDではない。A2参照 | 現行機能照合済み／内部CRUDの学校適用判断UNVERIFIED |
| デザイン1: 分かりやすいページタイトル・説明 | #95全HTML画面title | #95の23画面・27状態・320/390/768/1280px、期待exact title/path/h1 | 23画面・27状態・4幅のtitle/見出し監査証拠あり |
| デザイン2: 非技術者にも分かる案内 | #95見出し・操作案内・空状態 | #95実ビュー/画像照合。実際の教師/生徒によるユーザビリティ試験は未実施 | 画面案内の監査証拠あり／利用者試験は未実施 |
| デザイン3: 日本語表示・i18n | #94、#98日本語default locale統合記録 | #95エラー画面再利用、#98日本語locale下のmodel/service検証記録。全翻訳の総当たりを意味しない | 日本語locale・エラー表示の既存監査/試験証拠あり |
| デザイン4: エラー表示でレイアウトが崩れない | #94 Japanese error layout、#95 | #95に長文/複数入力エラー参照あり。全エラー×全画面×4幅の総当たりではない | 長文/複数エラーのレイアウト証拠あり／全組合せではない |
| デザイン5: 未完成・初期状態のデザインがない | #95全画面監査、#101/#102設計資料 | #95画像3種と空状態。後続UI・資料差分のレビュー記録を併用 | 既存全画面監査＋後続UI/設計資料更新のレビュー証拠あり |
| デザイン6: 要素が隠れていない | #95画面別表 | #95可視input/select/button寸法、PDF・footer等既存回帰。未確認状態は同文書参照 | 要素寸法・可視性・既存回帰の証拠あり／全状態の保証ではない |
| デザイン7: はみ出しがない | #95画面幅チェック | #95ページ全体の横幅・4幅画像。成績表の意図した内部scrollとdocument overflowを区別 | 4幅のdocument overflow/表内scroll監査証拠あり |
| デザイン8: header/footer（画面による例外可） | #91footer、#95画面監査 | #95既存footer/PDF回帰。画面別の例外・理由はA5で区分 | header/footerと画面別例外の監査証拠あり（A5） |
| デザイン9: header/footerの上下配置が適切 | #95全画面監査 | [390pxフロー](issue95-evidence/flow-390.jpg)、[tablet/desktop](issue95-evidence/tablet-desktop.jpg)。タブレット実機は未検証 | Chromeのmobile/tablet幅・desktop証拠あり／tablet実機未試験 |
| デザイン10: 適切なリンク名 | #95リンク名・戻る導線 | #95実ビュー/画像、成績→答案→保存後/戻り先。後続の文言・遷移図更新記録を併用 | リンク名・戻り先の監査と後続図/導線更新の証拠あり |
| デザイン11: 適切なボタン名 | #95ボタン名・操作チェック | #95可視button寸法/画面画像、既存フォーム操作回帰。後続guestボタン回帰を併用 | ボタン名・寸法の監査と後続guestボタン回帰の証拠あり |
| デザイン12: 明確な入力ラベル・placeholder | #95 label/placeholder照合 | #95実ビュー/画像、フォームinput/select寸法。placeholderだけをlabelの証明とはしない | label/placeholder・フォーム寸法の監査証拠あり |
| 画面遷移1: rootの設定 | [routes](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/config/routes.rb)、[home spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/requests/home_spec.rb) | #95 `home` exact path、基準routesのrootを照合済み／2026-10-23配備後の公開root200（古い404は履歴） | root設定・exact path試験・公開root200の証拠あり |
| 画面遷移2: 初回にトップを表示 | #89トップ、#95未ログイン画面 | #95 `/`。新規未認証セッションで公開URLからの初回遷移を確認 | 未認証home試験・公開初回導線の既存確認証拠あり |
| 画面遷移3: ログイン後に適切な画面へ | [#96](issue96_authentication_system_audit.md) | `spec/system/footer_spec.rb:35` の教師/生徒/管理者loginと到達先（#96記録） | 3roleのログイン到達先・認証System証拠あり |
| 画面遷移4: 不適切・不要な遷移がない | #95戻り条件、#96認証境界、#99 | #95答案のcontext保持・不正context拒否、#96logout/history/切替。後続の図・公開導線確認記録を併用 | context保持/拒否・logout/切替・後続導線更新の証拠あり |
| 機能1: ログイン機能 | #96教師/生徒/管理者認証 | `spec/system/authentication_access_spec.rb` と既存 [footer_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/footer_spec.rb)。成功/失敗/切替 | 3roleの成功/失敗/切替の既存System証拠あり |
| 機能2: 管理者機能 | #96管理画面、#97アカウント操作 | `spec/system/admin_account_management_spec.rb`、#97 account CRUD。管理範囲は学校境界を保持 | 学校限定の管理画面・アカウント操作の既存System証拠あり |
| 機能3: 管理者・一般ユーザーのゲスト | [#93](issue93_production_demo.md)、[guest controller](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/controllers/guest_sessions_controller.rb)、#96 | `spec/system/guest_browsing_spec.rb`の既存証拠と下記2026-10-23公開3役Chrome/PDF確認。local証拠とlive観測を区別 | 公開3役閲覧確認済み／read-onlyの公式受入は学校判定 |
| 機能4: controllerで管理者アクセス制限 | [#96](issue96_authentication_system_audit.md)、[admin base controller](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/controllers/admin/base_controller.rb) | [authentication_access_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/authentication_access_spec.rb): 普通roleのadmin URL/PATCH拒否、学校境界、変更なし確認 | 未認証/role/学校等の許可・拒否のSystem証拠あり |
| 機能5: 一般ユーザーに管理者操作を表示しない | #96教師/生徒の管理リンク・form action不在 | [authentication_access_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/authentication_access_spec.rb) の画面非表示とcontroller拒否を別々に検証 | 一般roleでの管理操作非表示とcontroller拒否の証拠あり |
| System Spec1: ログイン機能のテスト | #96 role×operation表 | [footer_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/footer_spec.rb)、[authentication_access_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/authentication_access_spec.rb)（Chrome）、guestのdriver区別は機能3参照 | 既存証拠＋配備0812708全suite成功／提出対象変更時は再確認 |
| System Spec2: 各モデルのCRUD機能のテスト | [#97/#151モデル別C/R/U/D表](issue97_crud_system_audit.md) | 実Chrome配信→実jobの台帳pending/running/succeeded、確認親削除・取消/別台帳保持を追加検証。SystemとRequest/Service/Jobのみを区別。操作変種と運用処理の限界は表・A2参照 | ブラウザ代表経路の証拠補完済み／下位層のみ・適用判断UNVERIFIED |
| System Spec3: アクセス制限のテスト | #96拒否/許可表 | [authentication_access_spec.rb](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/system/authentication_access_spec.rb) の未認証・role・学校・作成者・配信範囲拒否と正例。Cancancan注記はA4参照 | 既存証拠＋配備0812708全suite成功／提出対象変更時は再確認 |
| System Spec4: 全System Specが成功 | 基準mainの[CI test job](https://github.com/arduino0420/quickflow/actions/runs/40079428699) | 過去の関連成功・失敗/診断は#95/#96/#97に限定記録。基準suiteは全Systemを含んで成功。区分単独の件数は本文から推定しない | 配備0812708全suite成功／公開guestを含む限定証拠は下記 |
| Model Spec1: すべての宣言済みvalidationのテスト | #98モデル別validation表、追加2モデルの宣言差分 | #98以降のmodel差分はAssignment pointer所属と新規台帳だけ。[台帳8例](https://github.com/arduino0420/quickflow/blob/21aff889e86391fe4a4b35508f07d5e54dd62c30/spec/models/question_generation_request_spec.rb)に加え、[Assignment Model Specの所属正例・別Assignment拒否](https://github.com/arduino0420/quickflow/blob/21aff889e86391fe4a4b35508f07d5e54dd62c30/spec/models/assignment_spec.rb#L17-L37)で属性エラーまで確認。A3参照 | 既存監査＋追加宣言のModel Spec証拠を照合済み／全分岐・全DB制約の網羅を意味しない |
| Model Spec2: 使用scopeのテスト | #98 explicit scope/enum記録、現行宣言差分照合 | [Assignment.distributed_to_school](https://github.com/arduino0420/quickflow/blob/21aff889e86391fe4a4b35508f07d5e54dd62c30/spec/models/assignment_spec.rb#L39-L61)の包含・別学校/未配信除外・重複排除・空集合、[GradingResult.pending_review](https://github.com/arduino0420/quickflow/blob/21aff889e86391fe4a4b35508f07d5e54dd62c30/spec/models/grading_result_spec.rb#L31-L40)の包含・判定済/正解/不正解除外。現行の明示scopeはこの2件で追加なし。enum mapping/predicateと生成scope queryの検証は区別する | 明示2 scopeのModel Spec証拠を現行と照合済み |
| Model Spec3: 成功・失敗の両方をテスト | #98各行の正例/負例、追加宣言の正負 | 空・境界・重複・別学校/クラス・更新拒否/正例は既存監査。追加台帳8例は全stateの正例とpresence/inclusion/複合一意性の正負、追加pointer2例は自Assignment許可・他Assignment拒否/該当属性エラー。固定sourceは上記Model1リンク | 既存監査＋追加宣言の正負を照合済み／今回のAssignment Model Specは29例・失敗0、既存service証拠も維持 |
| Model Spec4: 全Model Specが成功 | 基準mainの[CI test job](https://github.com/arduino0420/quickflow/actions/runs/40079428699) | #98のmodel+PasswordPolicy393例/0失敗は過去の限定範囲。基準suiteは全Modelを含んで成功。区分単独の件数は本文から推定しない | 配備0812708全suite成功／公開guestを含む限定証拠は下記 |

### 適用判断（要件本文を変更しない）

- **seed方針の確認報告:** 所有者は、12業務表各5件以上・内部運用表は理由付き除外・架空履歴を作らない方針について「確認は取れました。私たちの方針で良いそうです」と報告した。[#150の確認報告](issue150_seed_table_audit.md#適用方針の確認報告所有者報告)を開発9の現在の適用根拠とする。以下A1のUNVERIFIEDは報告前の監査履歴であり、全40物理表の実測値やNOT METという文字どおりの判定を変更しない。この報告を内部CRUDの適用承認、通常認証付き本番PDFの独立検証、学校の公式卒業合格へ拡大しない。

- **A1 / 開発9:** #92/#93の技術完了と公開配備を分ける。通常 `db:seed` ではデモを生成しない。明示的・隔離されたseedと12業務表各5件以上の証拠を用いる。認証counter、queue/cache/cable、variant、Rails metadata、内部要求台帳は真正な処理の運用状態であり、架空履歴を作らない。#47要求台帳は合成教材で0件/pointer nilとする運用理由を基準schemaとmanifest方針に結び付ける。**「各テーブル」の要件は削除せず、全物理表5件達成とも公式免除とも記載しない。** 基準sourceはprimary17表（14アプリ＋3ActiveStorage）、具象ApplicationRecord14モデル。別DBはcache1・queue13・cable1表。12初期業務表、認証counter、要求台帳、3添付表を区別し、全物理表5件の達成とはしない。要求台帳0/pointer nil、Submission claim3列nilは合成デモの実方針で、旧manifestは自動rebaselineしない。 [#150](issue150_seed_table_audit.md)でprimary19（data17+metadata2）、別DB21（data15+metadata6）、合計40物理表を隔離実測。既存12業務表のMETと全物理表NOT MET、適用判断UNVERIFIEDを分離した。
- **A2 / 開発10・System2:** #97の直接/間接操作、機能なし、運用CLI、System/Request/Serviceを区別する。「各モデルのCRUD機能」を「対象モデルのみ」に書き換えない。既存機能のないTeacher削除や内部モデルの公開CRUDをチェック欄のために増設しない。既存実装に即した根拠を記録し、全モデル完全CRUDや公式免除を主張しない。#151で具象14モデルと表を照合し、後続QuestionGenerationRequestを補完。台帳failed/enqueue_failed等の下位層のみの変種と運用CLIはSystemへ読み替えず、全変種/内部処理の学校適用判断をUNVERIFIEDとする。
- **A3 / 開発6・Model1–3:** #98は当時のモデル/schemaの証拠。全ての数値/書式/enum/学校整合をDB CHECKでも重複実装しているとは主張しない。validation/scopeがない内部モデルと抽象基底はその実装事実とサービス証拠を示す。追加台帳は[QuestionGenerationRequest](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/models/question_generation_request.rb)のpresence/state/failure_code/input一意性・belongs_toと[Assignment](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/app/models/assignment.rb)のpointer所属検証を、[lifecycle spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/services/question_generation_lifecycle_spec.rb)、[job spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/jobs/question_generation_job_spec.rb)、[fencing spec](https://github.com/arduino0420/quickflow/blob/9704b30fa90867a359d11a8ccf0cff78520aa5d2/spec/jobs/processing_claim_fencing_spec.rb)で補足。[PR135の専用Model Spec](https://github.com/arduino0420/quickflow/blob/acd22fb9e9f7241c3e434a147edc09f5f3a13ef7/spec/models/question_generation_request_spec.rb)で追加台帳のpresence/belongs_to/state/任意failure_code/複合scope一意性の正常・異常を8例確認し、上記main CIでも成功した。この特定の補足を全14モデルの全宣言網羅という主張へ拡大しない。旧#98の棚卸しに対する追加行として、未証明の宣言単位があればM1/M3の要確認を保持する。
- **A4 / System3:** Cancancan固有テストが任意であることは、アクセス制限テスト全般の免除ではない。#96の実controllerを通る許可/拒否証拠を残す。
- **A5 / デザイン8:** header/footerの画面別例外は原文で許容されるが、各画面の実装と理由を記録する。その他のデザイン項目まで除外しない。

### 配備・提出の現在の記録と残る限界

配備identity/runtime/DB/storage/worker/TLS/Cookieと限定本番主要フロー・公開guest導線の技術証拠は下記のとおり。要件定義合格・設計差分連絡・最終提出は本人報告済み。通常教師/生徒PDFも本人から問題なしと報告された。審査者の閲覧権限・受理画面・正式な学校判定を担当者が独立確認したという意味ではない。下の2026-10-23記録等は当時の履歴として保持し、現在の未提出や未配備へ読み替えない。

要確認・未検証として残す区分（新規の未実装リストではない）:

- **開発5:** 独自404/500のコード/Request証拠はあるが、公開エラー画面の再確認・意図的live500は行っていない。
- **開発8・デザイン2/9:** Chromebook実機のpen/筆記、正式な利用者試験、tablet実機等の限界。今回の通常PDF確認を筆記/保存の新たな実機検証へ拡大しない。
- **開発10・System Spec2:** 内部CRUDの適用判断、下位層のみの操作変種は#97/#151表・A2の分類を保持。新しい未実装CRUD画面や、全変種をSystem確認済みという主張は追加しない。
- **開発4・機能3:** 学校の正式受入、read-only guestを十分とする明文解釈は未確定。実装済み3role guestの証拠とは分け、正式合格を宣言しない。
- **開発9:** 所有者が確認した12業務表の範囲はMET。全40物理表5件NOT METという実測は維持する。

### 本番の追加証拠（2026-10-23）

| 情報源 | 確認済み範囲 | 限界 |
| --- | --- | --- |
| 配備担当の実行記録（#51/#99既存配備欄） | source047ba388/image digest、Ruby4.0.6/Rails8.1.4/qpdf12.4.2、migration20本/最新20261022110000、volume/既存値/PDF保持、整合backupと隔離復元、約40秒maintenance、TLS/root/up/3login、Secure Cookie、worker heartbeat | 同一server backupは災害対策の証明ではない。HSTSなし。手動頻度/backup目安/保持方針は[runbook](issue51_predeployment_runbook.md)のとおり所有者合意済み、詳細閾値/Host/HSTS判断は残件 |
| 本番の専用架空データ・実行担当のUI確認 | 3role login/logout、学校限定admin一覧、教師からadmin拒否、教師判定0→5、生徒結果5/正解、Excel実download（数値5/未提出blank）、教材PDF、admin編集preview/cancel保持 | 実ユーザーdataの閲覧/変更/削除なし。adminの確定更新/削除はこの本番検証で実行しない。ローカルの別証拠と区別 |
| 通常Chromeの追加確認 | [教師iframe描画](issue99-evidence/production-chrome-teacher-pdf.jpg)。保存PUT200/DB操作1件を確認し、Chromeで「保存済み」を待って既存筆跡表示→1回reload→「保存済み」→[同じ線の復元](issue99-evidence/production-chrome-draft-restored.jpg) | 初回の「保存失敗」は復元完了観測不足で撤回。IAB黒PDFの内部原因は未確定。全PDF/全browser/実端末の保証ではない。追加筆跡/正式提出は不要で未実行 |
| 所有者の報告（親から受領、担当の独立観測ではない） | 通常UXに問題なし。実AIによる配信・提出・採点も実施し、問題なし | 使用データ/全結果/料金/精度を担当が監査したものではない。担当自身のAI実行や有料テストの成功とは記載しない |

確認用データは明示して保持。専用教師と未提出生徒のみ承認済みpassword reset後にChrome確認し、session終了/一時secret破棄。credential・内部ID・私有server pathを本文や画像に掲載しない。当時のPDF/筆跡再表示の観測不足には実装修正/再配備が不要だった（後日のpen/palm修正とは別件）。#99の公開記録には本追補の反映がまだ必要であり、未投稿の追記にURLがあるとは扱わない。

公開guestは[runbookの実構成](issue51_predeployment_runbook.md#公開guest評価導線同一server架空データ専用)のとおり確認済み。個別架空アカウントによる学校本番の試験と、独立guestの証拠を混ぜない。原文の管理者/一般ユーザーguestは必須であるが、read-only十分との明記はなく、別serverも要件ではない。工学的最小解釈と学校の合格判定を区別する。

### 前版1adb1530の公開確認（履歴）（2026-10-23）

- 通常/guestのsourceは上記1adb1530、app image `sha256:77c3ea0a189c6ff41ff4d61d87c177df8894e00d59c35a2a49d205f07934863a`。[通常app](https://13-231-93-159.sslip.io/)から[guest入口](https://qfd-4c18332acca47671.13-231-93-159.sslip.io/)へ遷移を確認。12:45:27–12:46:42 UTCの約75秒maintenanceで、queue/claim静止3回→旧worker正常停止→新web/worker→再開。DB移行・seed・データrollbackなし。migration/同一storage mount継続、旧image/backup保持。詳細は[運用記録](issue51_predeployment_runbook.md)。
- 実行担当の通常Chrome確認: 大きいロゴ、元の説明2文、教師/生徒/guestの同色・指定順のボタン、既存2login画面とguest遷移。公開CSSは丸1.1rem/移動10px・reduced-motion保持、不要案内除去。実AIを使う採点中状態は再実行せず、過去の24例/失敗0の合成表示証拠と、今回のserved asset/partial確認を区別する。
- 公開guestの3役login/表示/終了、教師と生徒の答案PDFの実描画を通常Chromeで確認。専用架空DB/storage/鍵、readonly業務権限とmanifest、別host/namespace、両段厳密TLS、Origin/他校/書込/転送header拒否、PDF/Excel形式確認を記録。64KiB body制限とupstream接続上限2を維持するが、厳密な同時要求数2ではない。864MiB/1CPU ceiling、0worker/AI、新serverなし。全PDF/全browser/ピーク負荷/実学校受入の証明ではない。
- 通常root/up/3loginとguestは200、通常sessionはSecure/HttpOnly/Lax/Path=/。新Supervisor(fork)/Worker/Dispatcher/Scheduler各1の最近heartbeat、観測時queue5分類/active claim0。通常Caddy設定はmaintenance前と一致、guestは既存Let’s Encrypt account/同意済みtermsを再利用。HSTS未設定・Rails Host強化未追加の監査結果は保持し、課題にない追加必須項目としない。
- 所有者の以前の「通常UX・実AI配信/提出/採点は問題なし」という報告は上表の出典のまま。今回の担当による実AI再試験、全精度検証、卒業合格へ読み替えない。#99のコメント追記は以前のtool target ambiguityによる拒否のまま未投稿で、別routeで再投稿していない。この独立して承認済みのrepo文書更新は、拒否されたコメントの投稿成功とは扱わない。

### その後の実機報告と配備済みペン修正（2026-10-23）

所有者から、Lenovo500e Chromebook Gen4s (Light)付属ペンが指と同じ挙動で書けなかったと追加報告を受領した。以前の通常UX成功報告より後の実利用上の残件であり、開発8/#99を全操作完了とは扱わない。正確なSKU・ChromeOS版・実機のpointerType/cancel記録は未取得。製品familyにはpenの構成違いがあるため、型名だけで機器故障/対応規格を断定しない。

別途、現行controllerで「2点のtouch接触が残ると明示的penもpinchとして拒否」「筆記中の2点touchが線を終了」を合成イベントで再現した。配備した修正は明示的penだけを優先し、筆記中のpalmによるnative gestureをink面だけで抑止する。touchをpenへ変換せず、通常の指スクロール/ピンチ、read-only・viewport guard、保存/提出処理は維持する。実機報告の根因と同一とは未確認。上記acd22fb9の通常・guest配備と配布assetで修正の公開を確認したが、今回の認証付き本番筆記・保存は未実施で、ソフトウェア試験から実機解消を推測しない。付属ペンが実際にtouchとして通知されている場合は、この修正の対象ではない。既存の入力診断を使い、座標/答案/認証情報を共有せずpointer種別・取消・拒否理由の集計を確認する必要がある。

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

通知用本文案：要件・カタログ・テーブル定義、ER/画面遷移、ワイヤーフレームをコード9704b30に照合しました。役割別認証/管理者管理、担当クラス、PDF手書き/自動保存/提出、正答生成要求/claim、教師判定/Excel、閲覧専用ゲストの差分を上記資料へ整理しています。現在0812708の公開配備と限定確認が完了し、過去の復元実証・架空Chrome UI/PDF描画証拠を保持しています。実AI成功は所有者報告です。原本トップ・教師詳細・共通注記と遷移図を照合し、PR142の表示変更は配備済みとして区別しています。実端末/学校受入と実AIの独立再試験は未実施です。修正版資料の再投稿と変更通知は本人が別途実施します。

#102の実DoDは現行資料の整合、差分/対象外/今後の課題、通知内容の準備であり、**実送信を技術資料のclosure条件へ追加しない**。上記artifact/link確認と親レビュー後に#102の完了判断材料とする。このタスクはIssueをcloseしない。

#101/#103に残る本人のDPro再投稿・メンター通知・提出URL入力と完了画面確認は未完了。要件定義課題合格の本人確認も別。#51/#99は実測・最終CIと限定範囲を実DoDに照らして判断し、本人手続きが残る#101/#103/#88はopenを維持する。#105の実DoDは初学者ガイドと短時間の作品資料、実装との差異/機密露出なし。READMEの3ロール操作/失敗対処・選択済み合成画像と、日本語5枚の[編集PPTX](../presentation/quickflow-overview-ja.pptx)・[閲覧PDF](../presentation/quickflow-overview-ja.pdf)を収録。親タスクが最終pixelと構造/layoutを確認済み、本タスクも5枚/話者ノート/公開文言/秘密値不在を照合した。PDFは画像ベースで検索/編集不可、PPTXは編集可能。実導入効果/他ICTより優位という実証や利用者ヒアリングはしていない。#105はこの成果物と親レビューで完了判断できる資料として用意し、本タスクからcloseしない。

### 本人の最小手続き（#101/#103/#88、未実施）

1. 前課題「要件定義」が合格済みか、本人がDProで確認する。
2. 更新済みWhimsical/要件Sheet/ER/画面遷移/差分一覧の最終URLが審査者に閲覧可能か確認する。URL差替え・共有拡大は必要なら別承認。資料整合確認は親の17frame/Sheet同期記録、技術資料#102完了を使い回す。トップと採点結果のWhimsical原本2frameは2026-10-23に現行のロゴ/説明2文/3ボタン/閲覧guest導線・採点待機仕様へ更新し、snapshotで確認済み。他frameの内容や共有権限は変更していない。審査者の閲覧可否と実際の再投稿/通知は本人が確認する。リポジトリ内の旧生成SVG/PNGまで更新したとはしない。
3. 変更した要件/ワイヤーフレームの修正版をDPro課題ページへ再投稿し、既存の通知本文を更新してメンターへ変更点を知らせる。送信日時/リンクを本人が記録する。追加の「解釈承認」を必須gateにしない。
4. 確認済みのrepo URL/公開app URL/上記guest URLを提出欄に入力する。guestはパスワード入力不要の役割選択式である。学校本番の実accountやREADME公開secretは使わない。
5. 本人が最終提出し、完了画面/日時を確認する。#101は再投稿/通知記録後、#103/#88は実DoDの提出証拠後に完了判断。提出前に全Issueを閉じるため要件を弱めない。卒業合格/受理は学校側の結果に従い、技術完了と区別する。
