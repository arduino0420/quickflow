# 「配信」を押すと、登録・保存・一覧表示はどうつながる？

> 想定読者：QuickFlowを開発するRails学習者。今回は初心者向けという依頼に合わせています。コードと動作を並べると理解しやすい、という点は説明方法としての仮定です。
> 所要時間：約10分。再配信・追加配信・編集・削除・教材ダウンロードは扱いません。

伝えたいこと：**配信は「入力を全部確かめてから小テストと配信先をまとめて保存する処理」、一覧・詳細は「自分の配信済みデータだけを読み取る処理」です。**

読み終わったら、①不正なクラスが混ざっても一部保存されない理由、②自分の配信済み小テストだけ見える理由、③その保証をRSpecがどう確かめるかを説明できることが目標です。

<div class="table-wrap">

| 読む順番 | ここで分かること |
|---|---|
| routesとフォーム | ブラウザの入力がどのactionへ届くか |
| Controllerと入力検証 | 誰の小テストか、どのクラスが使えるか |
| transactionと関連 | Assignmentだけが残らない仕組み |
| 一覧・詳細とView | 保存したデータを安全に表示する流れ |
| Request Spec | 実際のリクエストで確認している範囲 |

</div>

## 1. routesは、ブラウザの行き先をactionへつなぐ

<!-- source: config/routes.rb -->
```ruby
resources :assignments, only: [ :index, :show, :new, :create ]
```

<div class="table-wrap">

| ブラウザのリクエスト | action | 役割 |
|---|---|---|
| GET /assignments/new | new | 配信フォームを表示 |
| POST /assignments | create | 登録と初回配信を保存 |
| GET /assignments | index | 配信済み一覧を表示 |
| GET /assignments/:id | show | 閲覧専用の詳細を表示 |

</div>

GETは画面を見る入口、POSTは入力を送る入口です。同じ `/assignments` でも、HTTPの種類によって一覧か保存かが決まります。

配信画面の `form_with model: @assignment` は、未保存Assignmentの入力フォームを作ります。教材のファイル欄も含めてPOSTし、クラス選択は `assignment[classroom_ids][]` という配列で届きます。

`new` は `current_teacher.assignments.build` で空のAssignmentを用意します。**buildは教師を設定したRubyオブジェクトを作るだけで、この時点ではDBに保存しません。**

## 2. Controllerは、まず教師を確認し、使ってよい入力を選ぶ

<!-- source: app/controllers/assignments_controller.rb -->
```ruby
before_action :require_teacher_login
```

これは各actionより前の教師確認です。`current_teacher` はsessionの教師IDから取得され、見つからなければ教師ログイン画面へ303で戻します。

`create` はログイン教師の関連からAssignmentを作ります。入力から教師IDを採用しないので、別の教師IDを送っても所有者を変更できません。

<!-- source: app/controllers/assignments_controller.rb -->
```ruby
params.require(:assignment).permit(:title, :point_per_question, :material_file)
```

これがStrong Parametersです。「assignmentというまとまりから、この3項目を受け取る」という入力項目の許可であり、内容が正しいことまでは保証しません。

クラスIDは別に `permit(classroom_ids: [])` で許可し、検証します。Assignmentのbuildへそのまま渡さず、確認済みクラスだけを後で紐付ける設計です。

## 3. validationと学校内IDの確認は、保存を始める前に行う

`@assignment.valid?` は、モデルの入力チェックを実行します。タイトルは必須、1問あたりの点数は1以上の整数です。まだ保存はしません。

教材必須は今回の初回配信処理に限る条件なので、Controllerが未添付時にエラーを追加します。モデル全体に教材必須のvalidationは追加していません。

配信先はログイン教師と同じ学校から取得します。

<!-- source: app/controllers/assignments_controller.rb -->
```ruby
@classrooms = Classroom.where(school_id: current_teacher.school_id).order(:grade, :class_number)
```

学校だけで絞るため、同じ学校なら他教師が担当するクラスも選べます。`Classroom.teacher_id` は制限に使いません。

ID確認は、配列か → 正の整数の文字列か → 空文字除去・重複除去 → 最低1件か → 全IDが学校内に存在するか、の順です。空文字はフォームの隠し入力から届くため除外しますが、空文字だけなら未選択エラーです。

例えば学校内のIDが10と20なのに、10と別学校の99を送ったとします。学校内検索は10しか返さず、要求した `[10, 99]` と一致しないのでリクエスト全体を拒否します。

**「使える10だけ保存する」ことはありません。** エラーが1つでもあれば保存開始前に422でフォームを返します。

## 4. transactionは、小テストと全配信先を一まとまりにする

<!-- source: app/controllers/assignments_controller.rb -->
```ruby
    Assignment.transaction do
      @assignment.save!
      selected_classrooms.each do |classroom|
        @assignment.assignment_classrooms.create!(classroom: classroom)
      end
    end
```

`save!` がAssignmentを保存し、そのIDを使って配信先のAssignmentClassroomを作成します。末尾の `!` は失敗を例外として知らせる呼び出しで、途中の失敗をtransactionの外まで伝えます。

transactionは、DBの変更をまとめて確定し、途中で例外が出れば巻き戻す仕組みです。2クラス目の保存が失敗すれば、Assignmentも1クラス目の紐付けも取り消します。

validationによる `RecordInvalid` はtransactionの外で受け取り、エラー付きフォームを422で表示します。例外を内側で握りつぶして確定させる構造ではありません。

### Model / Associationは、保存した行同士の関係を表す

<div class="table-wrap">

| モデル | 保存する意味 | 関連 |
|---|---|---|
| Assignment | 教師が作った小テスト本体 | belongs_to teacher、has_many assignment_classrooms |
| AssignmentClassroom | 小テストと配信先クラスの組 | belongs_to assignment / classroom |
| Classroom | 学年・組を持つクラス | Assignmentから中間テーブル経由で参照 |

</div>

Assignmentの `has_many :classrooms, through: :assignment_classrooms` は、「紐付けの表を通って配信先クラスを取得できる」という宣言です。選択が2クラスなら、小テスト1行と紐付け2行を保存します。

同じ小テストとクラスの組はモデルのuniqueness validationとDBのunique indexで重複を防ぎます。入力内のID重複も事前に除去します。

教材は `has_one_attached :material_file` によりActive Storageが管理します。DBのtransactionはAssignment・紐付け・添付情報を扱いますが、外部のファイルストレージ全体をDBと一緒に原子的に保証するものではありません。

## 5. 成功はredirect、入力エラーはrenderで返す

成功すると303で `/assignments/new` を開き直します。新しい `new` が空フォームを用意し、「小テストを配信しました」を表示します。

失敗時の `render :new` は、new actionを呼び直す命令ではありません。Controllerが用意したエラーと入力値を使って同じViewを表示します。

`render_creation_errors` は未保存Assignmentを作り直し、タイトル・点数・エラーをコピーします。途中保存後のロールバックでも、フォームが編集用に変わらずPOSTのまま再送信できます。

クラスの有効な選択も保持します。教材は引き継がず、画面の案内どおり再選択します。

## 6. 一覧は「自分のもの」かつ「配信先があるもの」を読む

<!-- source: app/controllers/assignments_controller.rb -->
```ruby
current_teacher.assignments.where(id: AssignmentClassroom.select(:assignment_id))
```

`current_teacher.assignments` が所有者を絞り、`where` が配信先の紐付けを持つAssignmentに限定します。`select(:assignment_id)` は中間テーブルから小テストIDだけを選ぶDBの問い合わせです。

これは `published_at` を見る処理ではありません。今回の「配信済み」は **AssignmentClassroomが1件以上あること**です。

`index` はこの範囲を `created_at` 降順、同時刻なら `id` 降順で並べます。一覧Viewがタイトルと `assignment_path(assignment)` への「詳細」リンクを表示し、0件なら案内を表示します。

中間テーブルの行を直接一覧に並べないため、複数クラスへ配信した小テストも一覧では1件です。

## 7. 詳細は、同じ取得範囲から1件を探して表示する

<!-- source: app/controllers/assignments_controller.rb -->
```ruby
@assignment = distributed_assignments.find(params[:id])
```

URLのIDだけで全Assignmentを探すのではなく、自分の配信済みの範囲から探します。他教師・未配信・不存在のIDなら404です。同じ学校の教師でも、他教師の小テストは閲覧できません。

`show` は `@assignment.classrooms.order(:grade, :class_number)` で配信先を読み取ります。show Viewはタイトル・1問あたりの点数・配信先クラス・教材ファイル名の4項目と、一覧へ戻るリンクを表示します。

GETで見るだけなので保存処理はありません。再配信・追加配信・編集・削除・教材ダウンロードのフォームやリンクもありません。

## 8. Request Specは、入口から保存・応答までを確認する

`spec/requests/assignments_spec.rb` は実際の教師・生徒ログインrouteを使い、GET/POSTを送って、保存件数・応答・HTMLを確認します。Controllerのメソッドだけを直接呼ぶテストではありません。

<div class="table-wrap">

| 確認すること | specの確かめ方 |
|---|---|
| 登録と配信を同時保存 | Assignmentが1件、選択数分の紐付けが増える |
| 教材・クラス必須、不正ID拒否 | 422、Assignment・紐付け・添付情報が増えない |
| 途中失敗を巻き戻す | 2件目の作成を失敗させ、1件目も残らない |
| 自分の配信済みだけ閲覧 | 他教師・未配信は一覧に出ず、詳細は404 |
| 閲覧がデータを変えない | 件数・属性・紐付けが変わらない |
| 画面の連携 | 初回配信→一覧→詳細を実際のリンクでたどる |

</div>

2026年10月6日に、この解説作成時点のrequest specを再実行しました。

```text
44 examples, 0 failures
```

これは上記のrequest specの範囲の結果です。ユーザーからRailsアプリのブラウザ確認完了が報告されていますが、今回のエージェントによるアプリ画面再確認とは区別します。

## 保存と表示の一本道

<div class="table-wrap"><table><thead><tr><th>配信する</th><th>配信済みを見る</th></tr></thead><tbody><tr><td>フォームからPOST</td><td>一覧・詳細へGET</td></tr><tr><td>routes → create</td><td>routes → index / show</td></tr><tr><td>教師確認 → 入力許可 → validationと学校内ID照合</td><td>教師確認 → 自分の配信済みを取得</td></tr><tr><td>transaction → 本体と全紐付けを保存</td><td>関連から配信先を読み取る</td></tr><tr><td>成功303 / 入力エラー422 → 配信View</td><td>一覧・詳細Viewを表示</td></tr></tbody></table></div>

## 理解度チェック

<details><summary>1. Strong Parametersを通ったクラスIDなら、そのまま保存してよい？</summary><p>いいえ。項目の許可とは別に、形式・存在・学校所属を確認します。別学校IDが混ざれば全部拒否します。</p></details>
<details><summary>2. 2クラス目の紐付けが失敗しても、Assignmentだけ残せる？</summary><p>今回の仕様では残しません。同じtransaction内で例外が伝わり、Assignmentとそれまでの紐付けもロールバックします。</p></details>
<details><summary>3. 同じ学校の他教師の小テストは、詳細で見られる？</summary><p>見られません。配信先選択は学校単位ですが、小テストの閲覧は所有教師単位です。</p></details>
<details><summary>4. 配信済みの判定にpublished_atを使っている？</summary><p>使っていません。自分のAssignmentのうち、AssignmentClassroomが1件以上あるものを取得します。</p></details>
<details><summary>5. request spec成功はブラウザの見た目まで保証する？</summary><p>しません。保存・応答・HTMLの確認と、実ブラウザでの表示や操作の確認は別です。</p></details>
