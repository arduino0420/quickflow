# #103 必須要件の証跡チェック（提出未完了）

基準source: [main 5b5689c](https://github.com/arduino0420/quickflow/commit/5b5689c9bda13e286b24592e6a49c822ef50b146)、2026-10-22。
原文URL: [DPro curriculum 3027](https://diver.diveintocode.jp/curriculums/3027)。本タスクでは認証ブラウザを開かず、原文を独立再読していない。親タスクが原文全文を確認したとのhandoffと、[Issue88](https://github.com/arduino0420/quickflow/issues/88)・[103](https://github.com/arduino0420/quickflow/issues/103)および下記子Issueの記録を用いた二次照合である。原文39項目の逐語内容はこの文書で捏造しない。最終提出表では人間が原文の各項目を転記して下記証拠を1対1に結ぶ。

状態は「OK（実装/テストの限定された証拠あり）」「要確認」「未対応」。公開稼働・公式合格・公式免除を技術Issue完了から推定しない。追加のメンター解釈確認を停止条件にはしない。

| 必須カテゴリ（#103が記録する項目数） | 証拠と確認範囲 | 提出前状態 |
| --- | --- | --- |
| 開発1–10（10項目） | `.ruby-version` Ruby4.0.6、Gemfile.lock Rails8.1.4、README。#89トップ/#90日本語エラー/#92初期data/#94表示/#98検証/#99例外/#97CRUD。#92は開発9、#98は開発6、#97は開発10、#99は開発2/8というIssue記載で照合 | 要確認: 各原文行へ対応付け、最終head/CI/EC2・公開動作を確定 |
| デザイン1–12（12項目） | [#95画面別監査](issue95_screen_audit.md)、#91footer、#94日本語、READMEと設計資料 | 要確認: 原文12行への対応と最終設計資料/共有権限。#101再投稿未完了 |
| 画面遷移1–4（4項目） | routes、[画面遷移図](../screen_transition.png)、#95、#99（3/4） | 要確認: 最終UI/図/原文行照合、公開例外確認 |
| 機能1–5（5項目） | [#96認証/認可表](issue96_authentication_system_audit.md)（1/2/4/5）、[ゲスト](issue93_production_demo.md)、#97フロー、#99 | 実装証拠OK。要確認: 公開ゲストURL/実環境と機能3の原文対応 |
| System Spec1–4（4項目） | #96（1/3/4）、[#97 CRUD表](issue97_crud_system_audit.md)（2/4）。Chromeとrack_test、Request/Service補助証拠の区別を各文書に記載 | 実装済み対象の技術証拠OK。最終head全CIは要確認 |
| Model Spec1–4（4項目） | [#98 validation/scope表](issue98_model_spec_audit.md)、#50責務、#47追加model/spec | 従来監査表と追加台帳の差分を最終headで再照合、CI要確認 |

39項目すべてに、原文番号/本文、OK・要確認・未対応、対応commit、test pathと実行環境、証拠URL/screenshot、制限/未検証範囲を記入する。カテゴリ単位のOKを39行の一括OKに展開しない。未対応ゼロを確認するまで「全必須充足」としない。

## 根拠のある適用判断

- 初期データ: [#92手順/全表棚卸し](issue92_safe_demo_seed.md)と[production demo](issue93_production_demo.md)。12業務表各5件以上と正規PDF添付の証拠を使う。内部認証counter、queue/cache/cable、variant、Rails metadata、#47要求台帳等は本物の操作から生じる状態で、架空履歴を捏造しない。合成教材は要求0件/pointer nil。これは根拠を示した実装上の適用判断であり、全物理表5件の達成/公式免除の主張ではない。
- CRUD: #97表の直接/間接操作、機能なし、運用CLIを区別する。Teacher削除等の未実装操作や内部モデル用CRUD画面を新設しない。機能のある操作をSystemで検証した範囲と、Request/Serviceだけの証拠を区別し、全モデル完全CRUDの主張をしない。
- 推奨品質#104、任意#105は必須39項目と混同しない。

## 人間による最終証拠・提出チェック

- [ ] 前の要件定義課題が合格済みと本人が確認（GitHubから判定不可）。
- [ ] 原文39項目に1行ずつ証拠/最終状態を記入し、未対応ゼロを確認。
- [ ] 最終main SHA/image、CI4ジョブ（test/lint/scan_ruby/scan_js）、RSpec件数・Ruby/Rails/PG/browser実行環境と既知制限を記録。#88記録の9bed9d2の1882例/0失敗は歴史的基準。最終対象CIと同一視しない。
- [ ] #46/PR123・qpdf/PR122の実merge状態を更新し、最終schema/依存/図/テスト/デモmanifestの整合を再確認。
- [ ] [#51/#99 runbook](issue51_predeployment_runbook.md)の実インフラ・backup/restore・job監視・主要フローの残件を閉じる。現在の公開HTTP観測はroot404、ログイン/health200で、新mainの動作証明ではない。
- [ ] owner承認後のAWS配備、EC2稼働、public TLS/HTTPS、実際の本番URL、**隔離デモ公開URL/ゲスト導線**を確認。現在は配備/デモ公開未実施。
- [ ] #101/#102の最終要件/カタログ/表定義/ER/画面遷移/ワイヤーフレームと実装を照合し、完成版の閲覧権限を確認。変更した設計資料を本人がDProへ再投稿し、課題投稿ページでメンターへ変更点を通知、日時/記録を残す（未完了）。
- [ ] リポジトリURLと公開アプリURLを本人がDProに入力。必要なら隔離デモ専用ログイン情報だけを提出欄へ記載。実学校アカウント/secretをREADMEやIssueへ掲載しない。
- [ ] 最終提出操作と完了画面の確認を本人が実施（未完了）。

本タスクはDPro投稿/通知/提出、公式卒業判定、live認証/AI、インフラ確認を行っていない。#51/#99/#103を文書だけでcloseしない。
