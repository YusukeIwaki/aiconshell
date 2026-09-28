# 外部サービスプラグインの追加

組み込みプラグインの設定は [GitHub](github/README.md)、[Discord](discord/README.md)
を参照してください。認証情報は DB のアカウントに持ち、管理画面のアカウント
ページで設定します。値や認証情報はリポジトリに保存しません。
Teams / Jira は後から同じアカウント方式で再サポートする予定です。

プラグインは信頼された Ruby コードとして登録します。MCP のように操作一覧と入出力スキーマを
公開しますが、MCP の通信プロトコルを実装するサーバーではありません。

## 宣言と登録

`lib/aiconshell/plugins/example.rb` に次のように宣言します。この例は構造の説明用で、
外部 API の取得処理は実装していません。

```ruby
require "aiconshell/plugins"

module Aiconshell
  module Plugins
    class Example < Base
      plugin_id "example"
      required_env "EXAMPLE_TOKEN"

      operation "latest_events",
        input_schema: Schemas::LATEST_EVENTS_INPUT,
        output_schema: Schemas::LATEST_EVENTS_OUTPUT,
        scope: "example:read",
        read_only: true

      private

      def handle_latest_events(input, context)
        require_credentials!(["EXAMPLE_TOKEN"]) unless present?(context.env["EXAMPLE_TOKEN"])
        # context.transport で取得し、正規化したイベントと継続 cursor を返す。
        { "events" => [], "cursor" => input["cursor"] || {} }
      end
    end
  end
end
```

`config/initializers/extra_plugins.rb` で一度登録します。

```ruby
require "aiconshell/plugins/example"
Aiconshell::Plugins::Registry.default.register(Aiconshell::Plugins::Example.new)
```

この名前空間は明示的に require するため、プラグインのコードを変更した場合は Rails を
再起動します。同じ ID の重複登録はエラーです。認証情報を用意し、
`AICONSHELL_ALLOWED_SCOPES=example:inbox` のように取得対象を許可すると、
定期ジョブが設定済みプラグインの `latest_events` を呼びます。操作の入力スキーマで
許容する scope を具体的に定義すると、スケジューラーでも検証されます。
組み込みプラグインの認証情報は DB のアカウントから渡し、プロセス環境は
認証情報の fallback にしません。

## 契約

- `Registry#invoke` が入力と出力の JSON Schema 検証を毎回実施します。
  入力は外部 I/O の前、出力は呼び出し元へ返す前に検証します。
- `Registry#validate_input(plugin:, operation:, input:, context: {})` は I/O なしで
  操作・権限・入力スキーマを検証し、文字列キーに正規化した入力を返します。
  スキーマだけでは表せない入力間の制約は、任意の公開メソッド
  `validate_operation_input(operation, input)` で検証できます。既定は追加検証なしです。
  このフックは `validate_input` と `invoke` の両方で呼ばれます。
  認証情報・HTTP・DB・変更可能なアプリケーション状態に依存せず、純粋な検証に限定し、
  不正入力では `InputInvalid` を送出してください。ハンドラーの処理を先取りしません。
  組み込みの書込操作も宛先の構文をここで検証します。認証情報の読み込みは
  実行時に行うため、preflight の成功は外部配信の成功を保証しません。
- `required_env` と `configured?` は診断用です。アダプターは環境形ハッシュを
  受け取りますが、組み込み運用ではその内容を DB のアカウントから組み立てます。
  実行時の認証情報確認もハンドラーで行います。
  値とファイルの選択肢がある場合は `configured?` を実装し、README に説明します。
- 操作権限 `context["scopes"]` と投稿先の allowlist は別です。Interaction は許可された
  操作と宛先を確認します。カスタムプラグインの返信先は既定では `resource_id` 自体を
  allowlist と照合するため、返信に使う宛先も明示的に許可してください。
- イベントの `event_id` は外部オブジェクトごとに安定させ、`fingerprint` で内容の変更を
  区別します。親の更新日時だけで別イベントにすると、自分の返信が再び依頼になる場合が
  あるため、親の内容変更と子のコメントを区別します。
  組み込みの `github.issue` / `discord.message` は、
  PollService が現在のスナップショットと比較して A→B→A の復元も別の改訂として保存します。
  カスタムイベント型は `event_id` と `fingerprint` の組で重複排除されるため、
  復元も区別したい場合は外部サービスの改訂 ID などを fingerprint に含めます。
- `actor_type` は `human` / `bot` / `system`。サービスアカウントは
  `AICONSHELL_SELF_ACTOR_IDS=example:account-id` に設定し、返信の反響を取り込みません。
- cursor は再試行できる JSON オブジェクトです。読み残したページを飛ばす時刻更新は避けます。
  取得失敗は明示的なエラーとして返し、HTTP ページの継続先の origin を検証します。
- 新規課題、返信などの操作にも入出力スキーマを宣言します。未対応操作は
  `unsupported: true, reason: "..."` で一覧に理由を表示できます。
- 操作に明示の Boolean `read_only` を宣言します。既定は `false` で、catalog は
  常に `true` / `false` を返します。`latest_events` などの参照操作は `true`、
  返信・作成などの書込操作は `false` のままにします。
  `Interaction::QueryService` は `read_only: true` の操作だけを呼び出します。
  `validate` は同じ pure preflight を使い、`call` はさらに出力スキーマと
  JSON 128,000 バイト上限を検証します。Rails での既定の event sink は `WorkflowEvents`。
  単体テストでは `event_sink: nil` または明示した fake を注入できます。

`smartest/plugins/*_test.rb` の注入された transport / clock / env を使い、認証情報や
実アカウントなしで正常系、スキーマ違反、改ページ、重複、429、曖昧な投稿失敗を確認します。
各プラグインの README には環境変数、最小権限、取得範囲、cursor、投稿先、再試行の制約を記します。
