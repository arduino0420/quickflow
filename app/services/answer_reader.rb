
class AnswerReader
  MODEL = "gpt-6-astra"

  def initialize(api_key: Rails.application.credentials.dig(:openai, :api_key))
    raise "OpenAI API key is not configured" if api_key.blank?

    @client = OpenAI::Client.new(api_key: api_key)
  end

  def call(submission)
    submission.answer_file.open do |file|
      uploaded_file = @client.files.create(
        file: Pathname.new(file.path),
        purpose: "user_data"
      )

      response = @client.responses.create(
        model: MODEL,
        input: [
          {
            role: "user",
            content: [
              {
                type: "input_file",
                file_id: uploaded_file.id
              },
              {
                type: "input_text",
                text: prompt
              }
            ]
          }
        ]
      )

      response.output_text
    end
  end

  private

  def prompt
    <<~PROMPT
      添付されたPDFは、中学校数学の小テストの答案です。

      各問題について、印刷された問題文と、
      生徒が手書きした最終解答を読み取ってください。

      この処理では読み取りだけを行います。
      問題を解いたり、正答を生成したり、
      正誤判定・得点計算・解説を行ったりしないでください。

      【最重要ルール】

      生徒の解答を正しい答えに合わせて
      補正・推測してはいけません。

      例えば、正答が「x²−49」であっても、
      生徒が「x²＋49」と書いていれば、
      「x²＋49」と読み取ってください。

      特に以下を正答から推測して変更しないでください。

      ・＋ と −
      ・数字
      ・指数
      ・分数
      ・括弧
      ・文字
      ・ルート
      ・小数点

      【問題文の読み取り】

      ・印刷された問題番号と問題文を読み取る
      ・問題文の計算式や解法指定を忠実に読み取る
      ・問題文と生徒の手書きを区別する
      ・読めない問題文を推測して補完しない
      ・読み取れない問題文は null とする
      ・問題番号も確認できない場合は null とする

      【生徒解答の読み取り】

      ・生徒が実際に書いた内容を忠実に読み取る
      ・途中式と最終解答を区別する
      ・解答欄がある場合はそこに残された最終解答を優先する
      ・途中計算から最終解答を補正しない
      ・取り消された解答は最終解答に含めない
      ・訂正前後が不明な場合は推測しない
      ・複数解釈できる文字や記号は一つに決めつけない
      ・未記入と判読困難を区別する
      ・PDF上で解答欄自体が確認できない場合は、
        未記入と判断しない

      【読み取り状態】

      reading_status には次のいずれかを設定してください。

      readable:
      最終解答を明確に読み取れる

      blank:
      解答欄を確認でき、何も書かれていない

      unclear:
      記入はあるが、判読が困難

      ambiguous:
      複数の読み取り方や最終解答の候補がある

      unavailable:
      解答欄を確認できず、読み取り自体ができない

      【出力形式】

      必ず次の構造のJSONオブジェクトだけを返してください。

      {
        "problems": [
          {
            "question_label": "1(1)",
            "question_text": "3x + 2x を計算しなさい。",
            "student_answer": "5x",
            "reading_status": "readable",
            "reading_reason": "最終解答を明確に読み取れる"
          }
        ]
      }

      ・PDF内のすべての問題を順番に出力する
      ・problems は配列とする
      ・各問題について上記5項目を必ず含める
      ・読み取れない値は null とする
      ・未記入の場合、student_answer は null とする
      ・判読困難な部分を推測で補わない
      ・JSON以外の説明文を出力しない
      ・Markdownのコードブロックを付けない
    PROMPT
  end
end
