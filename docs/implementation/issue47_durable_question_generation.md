# Issue 47: 永続的な正答生成状態

新規配信は `question_generation_requests` に教材 Blob ID、設定モデル、prompt version の不変な要求を保存し、Assignment の `current_question_generation_request_id` で明示的に選択する。同一 Assignment・教材・モデル・prompt の組は一意。最新行から選択を推測しない。A が失敗して B を選択した後に A を選び直しても、A の失敗履歴を保持する。通常の配信操作で既存課題の再生成を行う機能は追加していない。

## 状態と確定境界

- `pending`: 配信と同じ primary DB トランザクションで要求／pointer を保存。教材の物理アップロード成功後、配信コミット後に要求 ID を含むジョブを enqueue する。
- `running`: Assignment の既存 `FOR NO KEY UPDATE` ロックで pending を claim し、乱数 token と started_at を API 処理前に確定する。重複、実行中断、古い時刻を理由に claim を奪わない。
- `succeeded`: 既存の API 呼び出しを含む Assignment トランザクションを維持し、全 Questions と成功を同時に確定する。API ロック短縮は Issue46 の対象。
- `failed`: 生成トランザクションのロールバック後、別の保護されたトランザクションで `generation_failed` と finished_at を保存。enqueue 拒否／例外はまだ pending の同一入力だけを `enqueue_failed` にする。本文、問題、API キーや例外メッセージを台帳へ保存しない。

成功・エラー・enqueue 失敗・提出への fan-out は要求 ID、同一 Assignment の現在 pointer、入力、状態、claim token を確認する。提出更新は既存の processing_generation・完了／失敗・既存結果の保護も維持する。古い教材ジョブが現在の提出を failed にすることはない。claim 後に対象が変わった要求は自動再実行せず、残った状態を診断対象とする。

primary DB とジョブキューは別の確定であり、原子的な enqueue は保証しない。配信コミット後・enqueue 前に停止すると pending、claim 後の停止では running が残り得る。永続的な意図により調査できるが、停止や再実行の安全性を自動判定するものではない。時刻の古さだけでは worker の死亡を証明できない。

## 既存データと復旧

migration は追加のみで、過去の試行を推測した backfill は行わない。要求 ID のない旧ジョブは AI を呼ばない。既存の有効な Questions は台帳なしでも従来どおり採点・表示・成績出力に再利用できる。`saved_questions` は検証だけを行い、要求やジョブを作らない。問題も台帳もない過去の課題は「未試行」ではなく `legacy_unknown` とする。モデルの現在環境値を変えても選択中の失敗を消したり AI を再試行したりしない。

遅い答案の採点は選択中の永続要求の失敗を参照する。読取専用 `Recovery::SubmissionInspector` は要求 ID、状態、入力一致、作成／開始／終了時刻、安全な failure code を追加表示する。既存の候補判定・明示的採点復旧の適格性や操作は変えない。新しい replay ボタン、再生成 worker、lease、Submission status はない。正常な削除操作だけが、既存の保護トランザクション内で pointer を外し、その Assignment の要求を削除する。

## 切替時の制約

これは切替作業の実行指示ではない。実運用では旧 web／worker と新処理を混在させず、正答生成を実行中の旧 worker がないこと、旧キューと教材・保存済み問題の状態を運用担当者が確認する必要がある。追加 migration とアプリ／worker の整合した切替が必要。旧ジョブが処理されても新しい要求は捏造せず AI を開始しないため、問題のない旧課題は自動的には進まない。既存の不明／停止データの照合・再実行は別途明示的な承認と調査の対象であり、この変更は live reconciliation を行わない。

## 合成デモ

PR117 の `TABLE_MODELS` に新テーブルを含め、明示的な seed ロック、空 DB 判定、スナップショット、production のテーブル／シーケンス inventory と runtime SELECT grant に反映する。合成教材は要求 0 件・pointer nil のまま。有効な合成 Questions を用い、架空の AI 履歴を生成しない。台帳は通常の business state であり認証カウンター例外の対象外。旧 manifest は新 inventory／Assignment 属性と一致せず fail closed。自動 rebaseline、reset、repair はない。

検証用 production スクリプトは新規 task cluster に限定し、台帳 INSERT/UPDATE/DELETE/TRUNCATE/ALTER と sequence 権限の拒否、台帳 grant の改変と旧 manifest の拒否も確認する。既存デモの refresh や実運用の migration／デプロイは実施していない。
