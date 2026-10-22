# 現行スキーマの全属性と制約

基準 commit: `1404453a24dce4f3661a7c6aee7fc570e8f6b683`。`db/schema.rb` のみから生成。モデル検証とは区別する。

NULL 可は明示。`options` は型の長さ・default 等を原文で保持。業務表と ActiveStorage は同一 DB の定義。

## active_storage_attachments / 添付

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| name | string | 不可 | null: false |
| record_type | string | 不可 | null: false |
| record_id | bigint | 不可 | null: false |
| blob_id | bigint | 不可 | null: false |
| created_at | datetime | 不可 | null: false |

Unique: record_type + record_id + name + blob_id

DB FK: blob_id → active_storage_blobs.id

## active_storage_blobs / ファイル情報

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| key | string | 不可 | null: false |
| filename | string | 不可 | null: false |
| content_type | string | 可 |  |
| metadata | text | 可 |  |
| service_name | string | 不可 | null: false |
| byte_size | bigint | 不可 | null: false |
| checksum | string | 可 |  |
| created_at | datetime | 不可 | null: false |

Unique: key

DB FK: なし

## active_storage_variant_records / 派生画像

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| blob_id | bigint | 不可 | null: false |
| variation_digest | string | 不可 | null: false |

Unique: blob_id + variation_digest

DB FK: blob_id → active_storage_blobs.id

## admins / 管理者

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| school_id | bigint | 不可 | null: false |
| user_id | string | 不可 | null: false |
| password_digest | string | 不可 | null: false |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |

Unique: user_id

DB FK: school_id → schools.id

## answer_drafts / 答案下書き

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| student_id | bigint | 不可 | null: false |
| assignment_id | bigint | 不可 | null: false |
| material_fingerprint | string | 不可 | limit: 64, null: false |
| format_version | integer | 不可 | default: 1, null: false |
| page_data | jsonb | 不可 | default: [], null: false |
| lock_version | integer | 不可 | default: 0, null: false |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |

Unique: student_id + assignment_id

DB FK: assignment_id → assignments.id; student_id → students.id

## assignment_classrooms / 配信先

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| assignment_id | bigint | 不可 | null: false |
| classroom_id | bigint | 不可 | null: false |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |

Unique: assignment_id + classroom_id

DB FK: assignment_id → assignments.id; classroom_id → classrooms.id

## assignments / 小テスト・配信

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| teacher_id | bigint | 不可 | null: false |
| title | string | 不可 | null: false |
| point_per_question | integer | 不可 | null: false |
| published_at | datetime | 可 |  |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |
| current_question_generation_request_id | bigint | 可 |  |

Unique: 主キー以外なし

DB FK: current_question_generation_request_id → question_generation_requests.id; teacher_id → teachers.id

## authentication_attempt_buckets / 認証制限・ゲスト有効期限

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| key_digest | string(64) | 不可 | PK |
| attempts | integer | 不可 | null: false |
| expires_at | datetime | 不可 | null: false |

Unique: 主キー以外なし

DB FK: なし

## classrooms / クラス

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| school_id | bigint | 不可 | null: false |
| teacher_id | bigint | 可 |  |
| grade | integer | 不可 | null: false |
| class_number | integer | 不可 | null: false |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |

Unique: school_id + grade + class_number

DB FK: school_id → schools.id; teacher_id → teachers.id

## grading_results / 採点結果

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| submission_id | bigint | 不可 | null: false |
| question_id | bigint | 不可 | null: false |
| student_answer | text | 可 |  |
| reading_confidence | integer | 可 |  |
| ai_judgment | integer | 不可 | null: false |
| teacher_judgment | integer | 可 |  |
| error_point | text | 可 |  |
| feedback | text | 可 |  |
| review_reason | text | 可 |  |
| ai_model_name | string | 不可 | limit: 255, null: false |
| prompt_version | string | 不可 | limit: 50, null: false |
| graded_at | datetime | 不可 | null: false |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |

Unique: submission_id + question_id

DB FK: question_id → questions.id; submission_id → submissions.id

## question_generation_requests / 正答生成要求

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| assignment_id | bigint | 不可 | null: false |
| material_blob_id | bigint | 不可 | null: false |
| model | string | 不可 | null: false |
| prompt_version | string | 不可 | null: false |
| state | string | 不可 | default: "pending", null: false |
| claim_token | string | 可 |  |
| started_at | datetime | 可 |  |
| finished_at | datetime | 可 |  |
| failure_code | string | 可 |  |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |

Unique: assignment_id + material_blob_id + model + prompt_version

DB FK: assignment_id → assignments.id

## questions / 設問・正答

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| assignment_id | bigint | 不可 | null: false |
| question_label | string | 不可 | null: false |
| position | integer | 不可 | null: false |
| question_text | text | 不可 | null: false |
| correct_answer | text | 不可 | null: false |
| grading_rule | text | 可 |  |
| answer_generation_model | string | 不可 | null: false |
| answer_generation_prompt_version | string | 不可 | null: false |
| answer_generated_at | datetime | 不可 | null: false |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |

Unique: assignment_id + position

DB FK: assignment_id → assignments.id

## schools / 学校

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| school_code | string | 不可 | null: false |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |

Unique: school_code

DB FK: なし

## students / 生徒

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| classroom_id | bigint | 不可 | null: false |
| attendance_number | integer | 不可 | null: false |
| password_digest | string | 不可 | null: false |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |

Unique: classroom_id + attendance_number

DB FK: classroom_id → classrooms.id

## submissions / 提出答案

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| assignment_id | bigint | 不可 | null: false |
| student_id | bigint | 不可 | null: false |
| status | integer | 不可 | default: 0, null: false |
| submitted_at | datetime | 不可 | null: false |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |
| extracted_text | text | 可 |  |
| processing_generation | integer | 不可 | default: 0, null: false |

Unique: assignment_id + student_id

DB FK: assignment_id → assignments.id; student_id → students.id

## teacher_classrooms / 担当クラス

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| teacher_id | bigint | 不可 | null: false |
| classroom_id | bigint | 不可 | null: false |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |

Unique: teacher_id + classroom_id

DB FK: classroom_id → classrooms.id; teacher_id → teachers.id

## teachers / 教師

| 列 | 型 | NULL可 | options |
|---|---|---|---|
| id | bigint | 不可 | PK |
| school_id | bigint | 不可 | null: false |
| user_id | string | 不可 | null: false |
| password_digest | string | 不可 | null: false |
| created_at | datetime | 不可 | null: false |
| updated_at | datetime | 不可 | null: false |

Unique: user_id

DB FK: school_id → schools.id
