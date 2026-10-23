# Issue #49: 一覧・Excelの得点計算

## 変更と境界

`Submission#score` の公開契約を変えず、教師成績一覧・生徒課題一覧・Excelだけを `SubmissionScores` に切り替える。1回の呼び出しで対象課題のQuestion IDと完成答案のGradingResultを各1回取得する。先読み済みの関連は使わず、呼び出しごとに新しく取得する。サービス内にキャッシュを保持しない。

Question ID配列の完全一致、空問題のnil、未提出と0点、教師判定優先、needs_review／未知値の非加点、整数の配点計算を維持する。UI、並び順、絞り込み、答案復帰先、40行のExcel仕様、スキーマ、AI処理は変更しない。単体答案の公開scoreは従来どおり毎回読み直す。

## 計測条件

比較元は main `9bed9d2b6e35e89e51b8d76d1aa76df3e9f01b41`。Ruby 4.0.6 / Rails 8.1.4 / PostgreSQL 18.6。独立clone、独立PostgreSQLクラスタ（127.0.0.1:55449、専用storage、quickflow_test）を使用し、Railsから実接続先を確認してからschemaをロードした。元の作業ツリー、既存DBには触れていない。

合成40生徒、3課題×10問、各答案に正解5問・要確認5問。Rails Integration::Sessionでログインし、実際のHTTPルーティング・controller・view・exportを通す。各経路2回ウォームアップ後9回計測。sql.active_recordのSELECTを計数し、cachedイベントを実SQLと区別。時間はCLOCK_MONOTONICによるリクエスト全体で、初期データ作成・ログインを含まない。計測専用トランザクションは最後にrollbackする。AI clientは生成禁止。

初回の時間は成績313→54ms、Excel203→44msだったが、対照の教師課題一覧まで16→9msに変動したため、速度比の根拠として採用しない。テストと重なった中間計測も破棄した。下表は合成テーブルをANALYZEした後、テストを並走させず変更前→変更後を順番に測定した結果。生の9回分は `issue49-before.json` / `issue49-after.json` に保存。

| 実経路 | 実SELECT 前→後 | cached 前→後 | 中央値ms 前→後 | 最小–最大ms 前 / 後 |
|---|---:|---:|---:|---|
| 教師課題一覧（対照） | 4→4 | 0→0 | 13.865→15.072 | 10.827–29.368 / 12.310–73.472 |
| 教師成績・40人 | 53→14 | 39→0 | 106.252→93.413 | 94.716–167.061 / 82.591–176.785 |
| 要確認絞り込み・40人 | 53→14 | 39→0 | 193.426→117.998 | 104.006–229.531 / 83.583–244.192 |
| Excel・40行 | 47→8 | 39→0 | 134.055→126.493 | 111.349–152.505 / 53.986–176.505 |
| 生徒課題一覧・3課題 | 14→10 | 0→0 | 29.704→29.139 | 23.815–33.609 / 25.448–54.714 |

9回とも各経路のSQL／cached件数は一定。得点用Question取得は変更前も同一課題で実SQL1回＋キャッシュ39回であり、「物理2Nクエリ」ではなかった。一方、得点用GradingResult取得は40回の実SQLであり、ここを1回へ集約できた。変更後の得点取得はQuestion／GradingResult各1回。成績画面には要確認件数の集計など別のSQLも残る。

時間分布は重なり、特にExcelは生成処理等も含むため、大きな速度向上を断定できない。採用根拠は実SQL39回とキャッシュ呼び出し39回の安定した削減、および同一の計算結果。ローカル時間から本番応答時間や速度倍率は約束しない。

## 回帰検証

- 40人の通常・要確認成績・Excelで、得点用Question／GradingResult取得が各1回であることをSQLイベントで検証（nested subqueryは得点取得に数えない）。
- 教師修正後の別HTTPリクエスト、生徒一覧とExcel、古いQuestion／結果の先読み、サービス再利用時の再取得。
- 欠落・追加・同数の別Question ID、空問題、未完了、未提出、0点、要確認、未知のAI値、配点・満点、他課題／他生徒の分離、保存データ不変。
- 既存の並び順・クラス選択・絞り込み・答案復帰先・権限制御テスト。
- 時刻を固定し、従来の公開scoreによる出力と、ZIP内全エントリおよびxlsx全体のバイト一致を検証。

検証結果：関連モデル・service・request・export 251 examples, 0 failures。生徒3課題のSQL回帰を追加後、対象request 2 examples, 0 failures。RuboCop 263 files, no offenses。ローカル全suiteの重複実行とChrome起動は行わず、全体検証はPR headのCIで行う。

## 再現

新規の合成データ専用PostgreSQLで、Railsの実接続先を確認してschemaを準備する。既存DBで実行しない。

```sh
RAILS_ENV=test DATABASE_URL=postgresql://127.0.0.1:55449/quickflow_test \
QUICKFLOW_BENCHMARK_PORT=55449 \
bundle exec rails runner docs/performance/measure_submission_scores.rb
```

比較元では同じ計測スクリプトを作業ツリー外へコピーして使用する。各版の実行は順番に行う。専用DBのみANALYZEする。実測値は環境負荷・DB統計・キャッシュ状態によって変わる。

## 受入前の保留

独立レビューまでdraftを維持する。#46のロック短縮とPR #122のPDF validatorは計測時のmainに未統合。実際の最終mainが更新された場合は取り込み、関連テストおよび最終headの全CIを再確認してから受け入れる。
