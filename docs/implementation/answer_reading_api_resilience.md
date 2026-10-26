# 答案読み取りAPIの一時エラーへの対応

## 分かったことと分からないこと

既存ログには答案読み取りjobの `OpenAI::Errors::InternalServerError` が残っていた。
固定SDK0.106.0はHTTP500以上をこの例外へ分類する。しかし当時は段階・HTTP番号・
request IDを記録しておらず、uploadとResponsesのどちらか、提供側の内部原因は特定不能。
保存済みファイルは存在し、サイズとchecksumが一致。同じ保存済み入力の単回再開は成功した。
これは一時障害と整合するが、外部内部原因や再発ゼロを証明するものではない。
個人・提出の識別情報、答案、API応答全文はこの資料に記載しない。

関連コードと固定SDKを照合した範囲では、PathnameによるFiles upload、purpose=user_data、
1時間の期限、Responsesのinput_fileとinput_text、store=falseは既存の対応形式。
qpdf preflight・保存checksum検証を維持し、モデル選択・prompt・採点基準は変更しない。
モデルは既存のtask別設定/shared fallback、base URLはSDK設定を使用する。
当時の実際のモデル・endpoint・提供側応答詳細は未記録であり推測しない。
SDKの既定自動再試行は接続失敗・timeout等も対象となるため、既存のmax_retries=0を維持する。
[公式SDKの再試行説明](https://github.com/openai/openai-ruby#retries)も参照。

## 限定する回復範囲

- AnswerReadingJobが取得した世代・claimの所有権を、**各API呼出し前**と再試行判断時に再確認。
  終了・削除・差替え・世代更新が観測されたら追加送信せず、従来のfinalizeで古い書込も拒否。
- HTTP500–599を明示的に受信した場合のみ、読取全体（upload＋Responses）で追加1回。
  1秒backoff。SDKはリクエスト単位でもmax_retries=0、job再試行は追加しない。
  正常時2外部リクエスト、最大3。Responsesだけの再試行では同じupload IDを再利用。
- 総送信時間予算は既存2リクエスト分のtimeout＋backoff1秒。
  既定では241秒。各リクエストのtimeoutは既存上限120秒と残り予算の小さい方。
  期限切れ、timeout・接続断等の結果不明、4xx、無効/拒否/未完了の応答は再試行しない。
- 枯渇時は従来どおりfailedを表示し、保存PDFを保持する。既知のupload IDは既存cleanupへ。
  uploadの5xxでIDが返らなければ明示cleanupできないが、既存の1時間期限を維持する。
- 診断ログは段階（upload/reading）、試行数、HTTP状態、安全な形式のrequest ID、retry/stopのみ。
  例外message/body/全headers/URL、資格情報、答案内容、生徒やPDFの識別情報は追加しない。

## 残る限界

5xxでも提供側が処理した可能性や追加料金はゼロにはできない。idempotency保証を仮定せず、
明示5xxだけの追加1回に制限する。timeoutは特に結果不明なので自動再試行しない。
ロックを保持して外部通信しないため、所有権確認直後に削除等が起きた場合の送信自体は
完全には取り消せないが、既存snapshot/claimによって古い結果の保存を防ぐ。
外部障害の防止、全端末・全入力・採点精度、提供側の処理時間の絶対上限は保証しない。
ゲストのreadonly/外部AI禁止、教師の最終判定、通常の筆記・保存・提出・採点は維持する。

検証は合成PDFとAPIスタブのみ。有料API・本番再採点は実施しない。
本番反映には別途レビュー済みreleaseの配備承認が必要。
