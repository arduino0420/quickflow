# 生徒はなぜ自分のクラスの小テストだけ見られる？

> 想定読者：QuickFlowを開発しながらRailsを学んでいる方。依頼で確認できたのは、ログインから教材取得までのつながりを理解したいことです。
> 仮定：短い実コードと具体例を並べると理解しやすいと考えています。経験年数や既知の範囲は未確認です。
> 省いたもの：解答提出・採点・一般的なRailsの導入手順。所要時間：約8分。

伝えたいこと：一覧・詳細・教材のすべてで「ログイン生徒の所属クラス」を取得の出発点にすることで、URLを書き換えても他クラスの小テストを取得できません。

読み終えたら、①ログイン後にどのControllerへ進むか、②他クラスのIDを指定するとどこで止まるか、③教材取得でも認可が必要な理由を説明できます。

## 一枚で：画面と内部処理

<div class="table-wrap">

| 節 | 役割 | 見せるもの | 理解につながる点 |
|---|---|---|---|
| ログインとroutes | 生徒用の入口を特定する | redirect・namespace | 教師用との分離 |
| 認証とassociation | 取得できる範囲を決める | current_studentからの関連 | URL直アクセスの防止 |
| indexとshow | HTMLを表示する | before_action・View | 詳細にも同じ制限 |
| material | 教材内容を返す | send_data・公開routes無効化 | ファイルへの迂回防止 |
| Request Spec | 何を確認できたかを区別する | 成功・404・回帰テスト | ブラウザ確認との違い |

</div>

## ログインすると、一覧への別リクエストが始まる

生徒ログインは学校コード→学年・組→出席番号で生徒を特定し、パスワードを確認します。成功すると既存セッションをリセットして生徒IDを保存します。

<!-- source: app/controllers/student_sessions_controller.rb -->
```ruby
      reset_session
      session[:student_id] = student.id
      redirect_to student_assignments_path, status: :see_other
```

`redirect_to`は一覧HTMLをここで作る命令ではありません。303の返答を受けたブラウザが、続いて`GET /student/assignments`を送ります。

ログインのStrong Parametersは入力項目を限定する処理です。パスワードの確認と、教材を取得してよいかの確認は別の処理です。

<!-- source: config/routes.rb -->
```ruby
  namespace :student do
    resources :assignments, only: [ :index, :show ] do
      get :material, on: :member
    end
  end
```

`namespace :student`はURL・Controller・helperの名前を生徒用にまとめます。`Student::AssignmentsController`の`::`は名前空間の区切りで、Studentモデルが教材を返すactionを持つという意味ではありません。

<div class="table-wrap">

| リクエスト | action | helper |
|---|---|---|
| GET /student/assignments | index | student_assignments_path |
| GET /student/assignments/12 | show | student_assignment_path(12) |
| GET /student/assignments/12/material | material | material_student_assignment_path(12) |

</div>

`on: :member`は「特定のAssignment一件」を対象にする指定です。教師側の`/assignments`と生徒側の`/student/assignments`は別のControllerへ進みます。

## 認証の次に、所属クラスで範囲を限定する

認証は「誰がログインしているか」、認可は「その人がこの小テストを取得してよいか」の確認です。ログインできたことだけでは、全教材の閲覧許可にはなりません。

<!-- source: app/controllers/application_controller.rb -->
```ruby
  def current_student
    Student.find_by(id: session[:student_id])
  end
```

生徒が未ログイン・削除済みなら`nil`です。教師ログインだけの場合も、生徒IDがないので生徒として扱いません。

<!-- source: app/controllers/student/assignments_controller.rb -->
```ruby
  def require_student_login
    redirect_to student_login_path, status: :see_other unless current_student
  end

  def available_assignments
    current_student.classroom.assignments
  end

  def set_assignment
    @assignment = available_assignments.find(params[:id])
  end
```

`current_student.classroom.assignments`は「その生徒の所属クラスへ配信されたAssignment」の検索範囲です。StudentはClassroomに所属し、Classroomの次のassociationがAssignmentClassroomを経由してAssignmentへつなぎます。

<!-- source: app/models/classroom.rb -->
```ruby
  has_many :assignment_classrooms
  has_many :assignments, through: :assignment_classrooms
```

たとえば1年1組の生徒が、1年2組だけに配信されたAssignmentのIDを指定しても、検索範囲にそのレコードがありません。`find`が`ActiveRecord::RecordNotFound`を起こし、Railsが404を返します。

クラスIDはブラウザから受け取らず、ログイン生徒のDB上の所属から決めています。同じ学校というだけでは取得できず、自分のクラスへの紐付けが必要です。

一方、自分のクラスと他クラスの両方へ配信された小テストは取得できます。作成教師や`Classroom.teacher_id`では制限せず、Issue #14で保存された配信先を使います。`published_at`の有無も条件にしていません。

## indexは一覧、showは詳細のHTMLを作る

<!-- source: app/controllers/student/assignments_controller.rb -->
```ruby
  before_action :require_student_login
  before_action :set_assignment, only: [ :show, :material ]

  def index
    @assignments = available_assignments.order(created_at: :desc, id: :desc)
  end

  def show
  end
```

`before_action`はactionより先に実行する処理です。全actionで生徒認証を行い、showとmaterialではその後に所属クラス内のAssignmentを取得します。

indexは新しい登録順に並べます。同じ登録日時ならIDが大きいものを先にし、Viewがタイトルと「詳細」リンクを表示します。0件なら「配信された小テストはありません。」です。

showが空でも、事前の`set_assignment`が`@assignment`を用意し、Railsが対応する`show.html.erb`を表示します。詳細にはタイトル・1問あたりの点数・教材ファイル名・教材リンク・一覧への戻りリンクだけがあります。

このGET処理では登録用validationやtransactionは実行しません。Issue #14が保存したAssignmentと配信の紐付けを読む機能です。

## materialは、認可した教材の中身を返す

教材のリンクを非表示にするだけでは、URL直アクセスを防げません。materialもshowと同じ`set_assignment`を通るため、**ファイルを読む前に所属クラスでの確認が済みます。**

<!-- source: app/controllers/student/assignments_controller.rb -->
```ruby
    file = @assignment.material_file
    return head :not_found unless file.attached?

    disposition = params[:download] == "1" || file.content_type != "application/pdf" ? :attachment : :inline
    response.headers["Cache-Control"] = "private, no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    send_data file.download, filename: file.filename.to_s,
      type: file.content_type || "application/octet-stream", disposition: disposition
```

`file.download`はサーバーがActive Storageから教材内容を読む処理です。続く`send_data`は、その内容・ファイル名・種類・表示方法をHTTPレスポンスとしてブラウザへ返します。別の公開URLへredirectしていません。

<div class="table-wrap">

| 操作 | disposition | ブラウザへの伝え方 |
|---|---|---|
| PDFの「教材を開く」 | inline | ブラウザ内での表示を指定 |
| 「教材をダウンロード」（download=1） | attachment | ファイル保存を指定 |
| PDF以外 | attachment | ブラウザ内では開かず取得 |

</div>

どちらのリンクも同じmaterial actionを通り、認証・認可は同じです。PDF表示や保存画面の具体的な挙動は、ブラウザの設定にも依存します。

Viewの`data: { turbo: false }`は、教材リンクを通常のページ移動として扱う指定です。HTMLの部分更新ではなく、PDFやファイルの返答をブラウザに扱わせます。

`private, no-store`はレスポンスを保存・再利用しないようキャッシュへ指示します。`nosniff`は指定したContent-Typeの扱いを促します。ダウンロード済みの利用者のファイルを削除する仕組みではありません。

添付がなければリンクを表示せず、教材routeは404です。保存先のファイルが見つからない場合も`ActiveStorage::FileNotFoundError`を捕まえて404を返します。

## Active Storageの公開routesを閉じた理由

標準のActive Storage Controllerは、署名付きURLを知る人にアプリの生徒認証・クラス確認を行いません。独自material routeを追加しても、標準URLが生きていれば認可を迂回する入口が残ります。

<!-- source: config/application.rb -->
```ruby
    config.active_storage.draw_routes = false
```

この設定で標準blob・proxy・disk・representation・direct upload routesを無効にしています。認証付きの独自Controllerを使う場合の設定として、[Rails公式ガイド](https://guides.rubyonrails.org/active_storage_overview.html#authenticated-controllers)にも説明があります。

Active Storage自体を削除したわけではありません。通常のmultipartフォームでの教師アップロード、添付のDB保存、サーバー内部のdownloadは維持されています。未使用のDirect Uploadや標準プレビューURLも利用できなくなる点は設定の影響です。

今回の保存先はDiskサービスの`storage`／`tmp/storage`で、`public`配下ではありません。将来保存先や公開配信設定を変える場合は、今回のroutes制限だけで十分か再確認が必要です。

## Request Specで守っていること

`spec/requests/student_assignments_spec.rb`は実際のGET・POSTを送り、認証・取得範囲・レスポンスを確認します。

<div class="table-wrap">

| 確認する境界 | テスト内容 |
|---|---|
| 一覧 | 自分のクラスだけ、順番、0件、複数クラス配信でも重複なし |
| 詳細・教材 | 他クラス・別学校・未配信・不存在IDは404 |
| 認証 | 未ログイン・教師・ログアウト後・削除済み生徒は拒否 |
| PDF取得 | 元ファイルとの内容一致、inline／attachment、ヘッダー |
| 公開経路 | 有効な署名情報でも標準URLがrouteとして存在しない |
| 閲覧専用 | GETで対象レコードを変更せず、提出等の操作を出さない |
| 連携 | 教師の配信→生徒ログイン→一覧→詳細→教材 |

</div>

2026-10-06に、生徒閲覧・生徒認証・教師配信・教師認証のrequest specを再実行し、90 examples, 0 failuresでした。全RSpecを実行したという意味ではありません。

ユーザーのブラウザ確認では、ログイン・一覧・詳細・PDF表示・ダウンロードが成功しています。他クラスの実データがなかったためURL直アクセスはブラウザ未確認ですが、request specでは詳細と教材が404になることを確認しました。

教材は全体をメモリへ読み込む実装で、Range対応はありません。request specの成功だけで、大容量ファイルの性能や全ブラウザのPDF表示まで保証しません。

## ログインから教材までの一本道

<div class="table-wrap">

| 順番 | Railsとブラウザの動き |
|---|---|
| 1 | POST /student/loginでパスワード確認、生徒IDをセッションへ |
| 2 | 303を受けたブラウザが一覧をGET |
| 3 | 生徒認証→所属クラスのAssignment取得→一覧View |
| 4 | 詳細をGET→生徒認証→範囲内でfind→詳細View |
| 5 | 教材をGET→生徒認証→範囲内でfind→添付確認 |
| 6 | downloadで内容取得→send_dataでPDF・ファイルを返す |

</div>

## 理解度チェック

<details><summary>1. ログインControllerが一覧HTMLを作っている？</summary>
いいえ。303で一覧URLを返し、ブラウザが新しいGETを送ります。そのGETをStudent::AssignmentsController#indexが受けます。
</details>

<details><summary>2. 同じ学校なら他クラスのAssignmentも取得できる？</summary>
できません。current_student.classroom.assignmentsに含まれることが必要です。別クラスだけのIDではfindが見つけられず404になります。
</details>

<details><summary>3. showが空なら、詳細にも認可がない？</summary>
認可はbefore_actionのset_assignmentで行っています。materialにも同じ処理が適用されます。
</details>

<details><summary>4. PDFを開くリンクと保存リンクで、認可は違う？</summary>
どちらも同じ認可付きmaterial routeです。違うのは返すContent-Dispositionで、inlineかattachmentかを決めます。
</details>

<details><summary>5. 独自material routeだけ追加すれば、標準URLも安全になる？</summary>
なりません。標準Controllerには所属クラスの確認がないため、公開routesを無効にして迂回経路を閉じています。教材の添付と内部downloadはそのまま使えます。
</details>
