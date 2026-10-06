# 「提出」を押すと、誰の答案がどう保存される？

> 想定読者：QuickFlowを作りながらRailsを学ぶ方。依頼で確認できたのは、提出画面から保存・重複防止までを理解したいことです。
> 仮定：短いコードと操作を並べると理解しやすいと考えています。既知の範囲は未確認です。
> 所要時間：約8分。省いたもの：AI採点、再提出、答案ダウンロード、Railsの導入手順。

伝えたいこと：提出する生徒と小テストはサーバーが決め、PDFを確認して一度だけ保存します。画面・Controller・DBの三段階で再提出を防いでいます。

読み終えたら、①他クラスへのPOSTがどこで止まるか、②PDFの名前だけでは足りない理由、③二重送信で既存答案が変わらない仕組みを説明できます。

## 一枚で：何をどこで決めるか

<div class="table-wrap">

| 節 | 役割 | 実コードの根拠 | 読めるようになること |
|---|---|---|---|
| モデルとroute | 誰のどの答案かを表す | belongs_to、単数resource | Submission一件の意味 |
| POSTと認可 | 保存可能な対象を限定 | 所属クラスからfind | ID改ざんへの防御 |
| PDFと保存 | 入力を確認して添付 | Marcel、save! | acceptと内容判定の違い |
| 提出済みと競合 | 上書きを防止 | persisted?、unique index | 二重送信への防御 |
| 応答とspec | 成功・失敗を区別 | 303、422、404 | 検証できた範囲 |

</div>

## Submissionは「この生徒が、この小テストへ提出した答案」

Assignmentは小テスト、Studentは生徒です。その二つをSubmissionの`assignment_id`と`student_id`が結びます。提出先クラスの紐付けであるAssignmentClassroomとは役割が違います。

<!-- source: app/models/submission.rb -->
```ruby
  belongs_to :assignment
  has_many :grading_results
  belongs_to :student

  has_one_attached :answer_file
```

`answer_file`は解答の添付です。SubmissionのカラムにPDF全体を入れるのではなく、Active StorageのAttachment・BlobがSubmissionと保存ファイルを結びます。既存の添付設定とテーブルを使うため、migrationは追加していません。

<!-- source: config/routes.rb -->
```ruby
      resource :submission, only: [ :create ]
```

これは生徒用Assignmentの内側にあり、`POST /student/assignments/:assignment_id/submission`を`Student::SubmissionsController#create`へ渡します。単数形は「この小テストへの自分の提出一件」を扱うためです。

単数resourceでもController名は複数形のSubmissionsControllerです。URLにSubmissionのIDは不要ですが、**単数routeだけでDBの一件制限ができるわけではありません。**

## 詳細画面からPOSTすると、認証と認可をやり直す

未提出の詳細画面には、解答PDFを選ぶフォームがあります。

<!-- source: app/views/student/assignments/show.html.erb -->
```erb
  <%= form_with model: @submission, url: student_assignment_submission_path(@assignment) do |form| %>
    <%= form.label :answer_file, "解答PDF" %>
    <%= form.file_field :answer_file, accept: "application/pdf,.pdf" %>
    <%= form.submit "提出" %>
  <% end %>
```

ファイル入力があるためmultipart形式で送信されます。POSTの入口では生徒認証を行い、未ログイン・教師ログインなら生徒ログイン画面へ戻します。

<!-- source: app/controllers/student/submissions_controller.rb -->
```ruby
    @assignment = current_student.classroom.assignments.find(params[:assignment_id])
    return redirect_already_submitted if existing_submission
```

URLのIDは、ログイン生徒の所属クラスへ配信されたAssignmentの範囲で検索します。他クラスだけ・別学校・未配信・不存在IDは範囲内に見つからず404です。詳細画面を開けたことだけに頼らず、保存するPOSTでも確認します。

例えば1年1組の生徒が1年2組専用のIDへPOSTしても、ファイル保存には進めません。自分のクラスにも配信されていれば、別の教師が作成した小テストでも提出できます。

## 生徒・状態・日時はフォームに決めさせない

<!-- source: app/controllers/student/submissions_controller.rb -->
```ruby
    @submission = current_student.submissions.build(
      assignment: @assignment, status: :submitted, submitted_at: Time.current
    )
    upload = params.fetch(:submission, ActionController::Parameters.new).permit(:answer_file)[:answer_file]
```

`current_student.submissions.build`が生徒を設定し、認可済みの`@assignment`が提出先になります。statusは提出済み状態の`submitted`、submitted_atはサーバーの現在時刻です。buildはまだDB保存しません。

Strong Parametersは`answer_file`だけを許可します。hidden入力でIDを送る方法でも入力は書き換えられるため、生徒ID・Assignment ID・status・日時をフォームから採用しません。

URLのassignment_idは検索の手掛かりですが、認可済みのレコードを得てから関連を設定します。「IDを受け取ったから信用する」とは違います。

## acceptは選択補助、Marcelはサーバー側の内容確認

`accept="application/pdf,.pdf"`はファイル選択画面の補助です。ブラウザ外から直接POSTできるので、これだけでPDF限定にはできません。

<!-- source: app/controllers/student/submissions_controller.rb -->
```ruby
    upload.tempfile.rewind
    pdf = File.extname(upload.original_filename).downcase == ".pdf" &&
      Marcel::MimeType.for(upload.tempfile) == "application/pdf"
```

その前に`ActionDispatch::Http::UploadedFile`であることを確認します。未選択や文字列などはエラーです。拡張子は大小文字を揃え、`.PDF`も認めます。

Marcelは既存のActive Storage依存です。判定に名前やブラウザ申告のContent-Typeを渡さず、一時ファイルの内容を読みます。テキストを`answer.pdf`へ改名し、`application/pdf`を申告しても通りません。

判定後もensureでrewindし、保存時に先頭から読めるようにします。この確認は今回の提出処理だけに置き、Submission全体のvalidationは変えていません。

PDFの特徴の判定と、全ページが壊れず読めるかの完全解析は別です。容量上限・完全解析は今回追加していません。

## 添付してから、Submissionを保存する

<!-- source: app/controllers/student/submissions_controller.rb -->
```ruby
    @submission.answer_file = upload
    Submission.transaction(requires_new: true) { @submission.save! }
    redirect_to student_assignment_path(@assignment), notice: "提出しました", status: :see_other
```

未保存Submissionへ添付を設定し、save!でモデルvalidationとDB保存を行います。Submissionだけを先に登録して、別操作で添付する流れにはしていません。

transactionはDB保存をまとめ、save!の失敗では例外を発生させます。`requires_new: true`は既存transactionがある場合にも保存範囲を分ける指定です。

注意点として、Active Storageの実ファイル転送はafter_commitです。DBのtransactionが、Disk障害まで完全に巻き戻す保証ではありません。今回のspecもストレージ障害への完全な原子性を保証していません。

## persisted?でフォームと提出済み表示を切り替える

詳細のshowでは、自分のSubmissionを検索し、なければ未保存のオブジェクトを作ります。

<!-- source: app/controllers/student/assignments_controller.rb -->
```ruby
    @submission = current_student.submissions.find_by(assignment: @assignment) ||
      current_student.submissions.build(assignment: @assignment)
```

Viewの`@submission.persisted?`がtrueなら「提出済み」、解答ファイル名、提出日時を表示します。falseなら提出フォームです。persisted?はファイルの有無ではなく、レコードが保存されているかの判定です。

保存失敗時には未保存Submissionを作り直し、errorsをコピーして詳細をrenderします。ファイルは再選択が必要です。提出済み答案を開く・ダウンロードするリンクはありません。

## 再提出は画面・Controller・DBで防ぐ

画面でフォームを隠しても、直接POSTや二重クリックはあり得ます。Controllerは既存Submissionがあれば保存せず「すでに提出済みです」と詳細へ戻します。

<!-- source: app/models/submission.rb -->
```ruby
  validates :student_id, uniqueness: { scope: :assignment_id }
```

さらにDBには`assignment_id`と`student_id`の組み合わせのunique indexがあります。事前検索とモデルvalidationを二つの同時リクエストが両方通っても、DBが二件目を拒否するため、最後の防御になります。

<!-- source: app/controllers/student/submissions_controller.rb -->
```ruby
  rescue ActiveRecord::RecordInvalid
    return redirect_already_submitted if existing_submission

    render_errors
  rescue ActiveRecord::RecordNotUnique
    return redirect_already_submitted if existing_submission

    raise
```

例外処理は保存transactionの外側です。既存Submissionを再検索し、競合相手の提出が存在すれば通常の重複と同じredirectにします。失敗したtransaction内で検索を続けません。

無関係なunique違反まで「提出済み」とは扱いません。既存提出が見つからないRecordNotUniqueは再raiseします。今回の通常の二重提出では、既存答案・日時・statusを変更しません。

## 422・303・404は次の行動が違う

<div class="table-wrap">

| 応答 | ケース | ブラウザの次の動き |
|---|---|---|
| 422 | PDF未選択・形式不正・通常のvalidation失敗 | 同じPOSTへの返答として詳細とエラーを表示 |
| 303 | 提出成功・提出済み | 指定された詳細URLを新しくGET |
| 303 | 未ログイン・教師ログイン | 生徒ログイン画面をGET |
| 404 | 所属クラスの範囲外・不存在Assignment | 対象を取得できず終了 |

</div>

renderは新しいGETを送りません。redirectはブラウザへ移動先を返します。成功後にGETへ移すことで、詳細の再読み込みで同じ提出POSTを繰り返す流れを避けます。

## Request Specが確かめている境界

<div class="table-wrap">

| 境界 | 確認内容 |
|---|---|
| 正常提出 | Student・Assignment・status・時刻・PDF内容の一致 |
| 入力改ざん | 送られたID・status・時刻を採用しない |
| 認可 | 他クラス・別学校・未配信・不存在は404、保存なし |
| 認証 | 未ログイン・教師・ログアウト後は保存なし |
| PDF | 未選択・不正入力・改名やContent-Type偽装を拒否 |
| 重複 | Submission・添付・日時・状態を変更しない |
| 競合 | RecordInvalid／RecordNotUnique経路でも提出済みへ戻る |
| 画面 | 未提出フォーム、422のエラー、提出済み表示 |

</div>

競合specは例外経路を再現したもので、実際の並列送信試験ではありません。DB自体の重複拒否は既存Submissionモデルspecで確認します。validation失敗specも保存例外の経路を再現しています。

ユーザーから、実装とブラウザ確認の完了が報告されています。この記事作成時のRailsアプリのブラウザ再確認は行っていません。関連RSpecの今回の再実行結果は記事冒頭の検証情報に記録します。

## 保存と表示の一本道

<div class="table-wrap">

| 順番 | 処理 |
|---|---|
| 1 | 詳細GETで自分のSubmissionを検索、未提出ならフォーム |
| 2 | 提出POSTを生徒用SubmissionsControllerが受ける |
| 3 | 生徒認証→所属クラスからAssignmentを検索 |
| 4 | 既存提出ならredirect。なければ生徒・状態・日時を設定 |
| 5 | ファイル形式・拡張子・Marcelの内容判定 |
| 6 | answer_fileを設定→transaction内でsave! |
| 7 | 303→詳細GET→persisted?がtrue→提出済み表示 |

</div>

## 理解度チェック

<details><summary>1. 単数resourceならDBの重複も防げる？</summary>
防げません。routeは一件を扱うURLの形です。重複防止はController・モデルvalidation・DBのunique indexが担当します。
</details>

<details><summary>2. 詳細を開けた生徒ならPOSTの認可は省いてよい？</summary>
省けません。POSTのURLは直接指定できます。保存前にcurrent_student.classroom.assignmentsから再検索します。
</details>

<details><summary>3. answer.pdfという名前とaccept属性でPDFを保証できる？</summary>
できません。サーバーで拡張子とMarcelによる内容判定も行います。ただしPDFの完全な破損検証ではありません。
</details>

<details><summary>4. 二人のリクエストが「未提出」を同時に確認したら？</summary>
同じ生徒・Assignmentの二件目はDBのunique indexが拒否します。transactionの外で既存提出を再確認し、上書きせず提出済みへ戻します。
</details>

<details><summary>5. 422のrenderと303のredirectは同じ移動？</summary>
違います。422はそのPOSTへの返答としてエラー画面を作ります。303ではブラウザが詳細やログインへ新しいGETを送ります。
</details>
