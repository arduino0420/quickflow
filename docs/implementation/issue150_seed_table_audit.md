# Issue #150: seed表別件数・適用範囲の再照合

基準: `68f37d6ec1cb5be228454ee9f4a006e0f4a840c3`、2026-10-24。
対象: [開発9の原文](https://diver.diveintocode.jp/curriculums/3027)「各テーブルそれぞれ5件以上」の初期データ。内部表の例外は原文に明記されていない。以下の実装上の分類は学校による例外承認ではない。

## 実測方法と結論

既存[#92手順](issue92_safe_demo_seed.md)に従い、新規ローカルPostgreSQL 18.6クラスタを使用。Rails実接続のDB名・loopback・非標準port・専用data directory・cluster IDを照合し、20 migrationを適用した。専用DBコメントとDisk印を用い、**guardをstubせず** `Demo::Seed#call` を2回実行。別の空DBに `db/cache_schema.rb` / `queue_schema.rb` / `cable_schema.rb` を読み込んだ。全DBのpublic表をPostgreSQL catalogから列挙し `COUNT(*)` とschemaを一対一で照合。稼働中本番や実レコードの件数ではない。

- **MET（限定範囲）:** 12初期業務表すべて5件以上。students10、questions50、grading_results50、正規PDF添付10件（blob10/attachment10）。既存#92の達成を維持。
- **NOT MET（文字どおり全物理表）:** 下表の0件表があるため、全表5件以上とは主張できない。
- **UNVERIFIED（学校適用判断）:** 内部要求台帳・認証counter・framework/運用DB・migration metadataを開発9に含めるか。公式な免除根拠は未確認。
- seed再実行前後で全対象行属性・ファイルdigest・manifestが不変。全seedモデルのvalidation成功、enqueue0、実AI禁止。終了後クラスタ停止、データ保持。正常なgeneration/failure/job履歴を捏造せず、seed実装を変更していない。

## 全物理表の棚卸し（40表 = data32 + Rails metadata8）

「5件要否」の業務初期データ=要。それ以外のUNVERIFIEDは学校の適用範囲が未確定という意味。migration metadataの件数はseed件数ではない。

| DB | 表 | seed前→後 | 分類・5件要否・根拠 |
|---|---|---:|---|
| primary | `active_storage_attachments` | 0→10 | 添付framework／UNVERIFIED（実添付として10件、独立の業務seedではない） |
| primary | `active_storage_blobs` | 0→10 | 添付framework／UNVERIFIED（実添付として10件、独立の業務seedではない） |
| primary | `active_storage_variant_records` | 0→0 | 添付variant／UNVERIFIED（PDF表示seedは画像variantを生成しない） |
| primary | `admins` | 0→5 | 初期業務データ／要／MET（有効な合成関連・表示データ） |
| primary | `answer_drafts` | 0→5 | 初期業務データ／要／MET（有効な合成関連・表示データ） |
| primary | `ar_internal_metadata` | 2→2 | Rails metadata／UNVERIFIED（migration/schema管理、seed対象外という公式根拠は未確認） |
| primary | `assignment_classrooms` | 0→5 | 初期業務データ／要／MET（有効な合成関連・表示データ） |
| primary | `assignments` | 0→5 | 初期業務データ／要／MET（有効な合成関連・表示データ） |
| primary | `authentication_attempt_buckets` | 0→0 | 認証counter／UNVERIFIED（失敗・期限窓の実状態。架空失敗を作らない） |
| primary | `classrooms` | 0→5 | 初期業務データ／要／MET（有効な合成関連・表示データ） |
| primary | `grading_results` | 0→50 | 初期業務データ／要／MET（有効な合成関連・表示データ） |
| primary | `question_generation_requests` | 0→0 | 内部要求台帳／UNVERIFIED（明示配信だけが生成。合成表示seedはpointer nil） |
| primary | `questions` | 0→50 | 初期業務データ／要／MET（有効な合成関連・表示データ） |
| primary | `schema_migrations` | 20→20 | Rails metadata／UNVERIFIED（migration/schema管理、seed対象外という公式根拠は未確認） |
| primary | `schools` | 0→5 | 初期業務データ／要／MET（有効な合成関連・表示データ） |
| primary | `students` | 0→10 | 初期業務データ／要／MET（有効な合成関連・表示データ） |
| primary | `submissions` | 0→5 | 初期業務データ／要／MET（有効な合成関連・表示データ） |
| primary | `teacher_classrooms` | 0→5 | 初期業務データ／要／MET（有効な合成関連・表示データ） |
| primary | `teachers` | 0→5 | 初期業務データ／要／MET（有効な合成関連・表示データ） |
| cache | `ar_internal_metadata` | 1（schema読込後） | Rails metadata／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| cache | `schema_migrations` | 1（schema読込後） | Rails metadata／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| cache | `solid_cache_entries` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `ar_internal_metadata` | 1（schema読込後） | Rails metadata／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `schema_migrations` | 1（schema読込後） | Rails metadata／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_batch_executions` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_batches` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_blocked_executions` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_claimed_executions` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_failed_executions` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_jobs` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_pauses` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_processes` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_ready_executions` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_recurring_executions` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_recurring_tasks` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_scheduled_executions` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| queue | `solid_queue_semaphores` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| cable | `ar_internal_metadata` | 1（schema読込後） | Rails metadata／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| cable | `schema_migrations` | 1（schema読込後） | Rails metadata／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |
| cable | `solid_cable_messages` | 0（schema読込後） | framework運用状態（cache/queue/cable）／UNVERIFIED（初期業務データでないという実装分類。公式除外は未確認） |

## 再確認用の最小手順

#92の隔離準備・実接続照合を完了した新規専用DBだけで `QUICKFLOW_DEMO_SEED=true bin/rails demo:seed` を2回実行。表一覧は `SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename`、各表の `COUNT(*)` で取得した。metadataはschema読込が作成した行として分離する。通常 `db/seeds.rb` はテンプレートのままであり、通常DBにこの作業を実行しない。

件数だけ合わせるための架空の失敗ログ・queue履歴・生成台帳は追加しない。もし学校の「各テーブル」がそれらを要求する場合は、正当な初期データの定義を確認するまで **UNVERIFIED** を維持する。新規公開CRUDや運用データ捏造で埋めない。
