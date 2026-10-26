# DPro卒業要件の追加監査と確認記録（2026年10月26日）

> **用途：** メンターへの提出説明と、残る確認事項の引き継ぎ。**DProへの正式提出・採点・卒業合格の記録ではありません。**
>
> **監査対象：** [QuickFlow main `5ef0b067932a1573e597f302d887117fda417551`](https://github.com/arduino0420/quickflow/commit/5ef0b067932a1573e597f302d887117fda417551)。正式な[オリジナルアプリケーションの課題本文](https://github.com/divic-corp/cdp_web_text/blob/master/text/ja/ruby_original_application_development/dep_original_application.md)を優先します。
>
> **表記：** `MET`＝指定範囲で根拠あり、`NOT MET`＝要件を文字どおり適用すると不足、`UNVERIFIED`＝必要な独立証拠・解釈が未確定、`NOT_RUN`＝今回未実行。GitHub Issueの完了とDProの合格は異なります。

## 1. 結論

最新mainに対する[CI実行 #40144687630](https://github.com/arduino0420/quickflow/actions/runs/40144687630)では、**全4ジョブ成功・RSpec 2,062件、失敗0件**です。主要機能・画面・モデル・認証の実装とテストは既存成果を維持します。

一方、39要件のうち以下の4項目は、今回の厳格な受入判断では独立した確認が必要です。**証拠の不足は新たなコード欠陥を意味しません。**

## 2. 未確定項目と必要な証拠

| 要件 | 判定 | 確認できた事実 | 追加で必要な確認 |
| --- | --- | --- | --- |
| 開発2：HerokuまたはEC2へデプロイ | 公開応答・稼働SHA確認済み（限定読取り） | 実行担当が2026-10-26 01:46 UTC、通常/guestのトップ・`/up`をTLS標準検証付きで読み取り、4 GETすべて200。02:09:31 UTCの承認済み限定読取りで通常/guestともrunning、revision `0812708fcc4d82dca02eb7d9e9c4594716d64e0b`、image `sha256:a09776739e008b98a23cb7659d1e9dc5123e9477f9af164e5c2358fcc915624a` を確認。[READMEの公開URL](../../README.md)、[運用runbook](issue51_predeployment_runbook.md)の過去の配備証跡とは区別 | 認証付き主要フローの現在の独立証拠は未取得。公開200やコンテナ状態だけを操作成功の証明にしない。設定・DB・データの操作なし |
| 開発8：利用中の予期しない例外を防止 | 通常PDFは本人確認報告あり／全経路はUNVERIFIED | RSpec成功、[主要動線の検証](issue103_submission_evidence.md)。通常教師/生徒PDFの確認依頼に対し、本人から「通常の教師・生徒ともPDF表示に問題なし」と報告。担当者の独立実機試験や、手書き全経路・全端末の確認へ拡大しない | 通常利用の手書き→保存→提出→結果閲覧、エラー時の表示について追加証拠が必要な場合は対象環境・日時・操作順を紐付ける。発生した例外・再現手順があれば対象範囲だけ修正 |
| 開発9：各テーブル5件以上のseed | NOT MET（全40物理表の文字どおりの解釈）／12業務表はMET | [独立DB実測](issue150_seed_table_audit.md)：12業務表は各5件以上。認証履歴、要求台帳、Solid Queue等の内部・運用表は0件あり。学校側へ業務表中心の適用範囲を確認済みとの本人報告あり | 独立証拠を補強する場合は、既存の学校回答の日時・要旨または記録を紐付ける。本人の確認済み報告を無効化せず、同じ方針の再承認を新条件にしない。履歴・認証失敗を件数合わせのため捏造しない |
| System Spec2：各モデルのCRUDのテスト | UNVERIFIED（一部の内部処理への解釈） | [14モデルのCRUD証拠対応表](issue97_crud_system_audit.md)と実画面System Spec。内部要求台帳等の一部変種はJob／Service／Request Spec | 「実装したCRUD操作」の定義を審査要件と照合し、必要なブラウザ操作テストの欠落が具体的に見つかった場合に限り補完 |

## 3. カタログ設計の高優先度4機能

[要件定義書](https://docs.google.com/spreadsheets/d/1G-4Q3SS79nOKc3IJGaaYNftkwM0XktCnIgPAiMZ-1ug/edit)に記載された「高」4件は、AI採点・フィードバック、配点と得点計算、成績Excel出力、PDF配信・手書き・管理を含む一連の操作です。[quiz_grading_workflow_spec.rb](../../spec/system/quiz_grading_workflow_spec.rb)で主要操作を検証しています。

テスト内の外部AI応答は固定の模擬応答です。**実APIの採点精度や全端末の動作を証明したものではありません。**

## 4. 提出手続きの区別

- **本人報告あり：** 前課題の要件定義合格、修正版の再投稿・メンター通知、卒業課題提出。
- **独立確認は未実施：** DProの投稿完了画面・時刻・メンター回答・正式な合否。
- **この変更の状態：** 提出用説明資料の更新候補。DPro画面への投稿や学校の判定を代行したものではありません。

## 5. 完了条件

1. 4項目の上記証拠を、確認日時・環境・対象コミットと紐付けて記録する。
2. 新たに実証された欠陥だけを修正する。未確認をPASS・未実行を実行済みとしない。
3. 既存の[#51](https://github.com/arduino0420/quickflow/issues/51)、[#99](https://github.com/arduino0420/quickflow/issues/99)、[#150](https://github.com/arduino0420/quickflow/issues/150)、[#151](https://github.com/arduino0420/quickflow/issues/151)の完了した作業は保持し、当時の適用解釈・確認範囲を勝手に拡大しない。
4. DPro提出・合否は、本人または学校の記録を確認できた場合に限って更新する。

## 6. 文章規範

[DIVIC CDS v1.0 #4253992](https://diveintocode.docbase.io/posts/4253992)／[日本語スタイル #4253986](https://diveintocode.docbase.io/posts/4253986)／[品質・承認 #4253990](https://diveintocode.docbase.io/posts/4253990)／[適用台帳 #4253991](https://diveintocode.docbase.io/posts/4253991)（確認日：2026-10-26）。コードやUIの色をDIVICブランドへ変更するものではありません。
