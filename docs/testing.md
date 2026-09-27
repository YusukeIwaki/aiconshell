# テストガイド

`bin/test` の使い方と、外部通信・AI プロセスを置き換える境界フィクスチャをまとめる。
HTTP 用は `smartest/support/boundary_fixtures.rb`、AI 用は
`smartest/support/scripted_ai.rb` を各テストから明示的に読み込む。

## スイート分割

- `bin/test unit` は `smartest/unit`、`smartest/plugins`、`smartest/ai` を実行する。
  DB・ネットワークサービス・ライブプロバイダ・資格情報なしで動く。
- `bin/test integration` は `smartest/integration` 全体を実 PostgreSQL に対して実行する。
  `TEST_DATABASE_URL` の DB 名は `_test` で終わること。ClickHouse 依存テストは
  実 ClickHouse がある場合にそれを使う。
- `bin/test all`（無引数の既定も同じ）は unit の後に integration を実行する。
  どのモードでも全 `smartest/**/*_test.rb` がちょうど 1 つのスイートに属することを監査する。
- ローカルの Postgres/ClickHouse への接続は、実 GitHub/Teams/AI アカウントへの
  外部呼び出しとは別物である。後者はテストから行わない。

## 実行方法

Ruby 3.4.9 と Bundler が PATH 上で有効な環境で実行する。

```sh
export TEST_DATABASE_URL=postgresql://localhost/aiconshell_test
RAILS_ENV=test bin/rails db:prepare
bin/test unit
bin/test integration
bin/test all
bin/rails zeitwerk:check
```

- `TEST_CLICKHOUSE_URL` を明示したのに到達できない場合、`bin/test` は
  事前確認で即失敗する。完全検証には実 ClickHouse が必要で、
  未設定のままでは ClickHouse 依存テストに skip が残りうる。
- 結合テストの初回は `db:prepare` が必要。Rails 配線を変えたら
  `bin/rails zeitwerk:check` も実行する。

管理依頼の受け入れ部分だけを実行する場合:

```sh
RAILS_ENV=test bundle exec smartest smartest/integration/acceptance
```

この部分は実 PostgreSQL と EventLog の PostgreSQL outbox を使う。
ClickHouse への配送・検索は別の結合テストで検証するため、完全検証では
上記の `bin/test all` と実 ClickHouse を使う。

## Ruby と依存関係

- Ruby は 3.4.9（`Gemfile` と `.ruby-version` が正）、依存関係はロック維持。
- rbenv ホストでは次のように Ruby/Bundler を指定できる。

```sh
RBENV_VERSION=3.4.9 rbenv exec ruby -v
RBENV_VERSION=3.4.9 rbenv exec bundle exec smartest smartest/unit
RBENV_VERSION=3.4.9 RAILS_ENV=test rbenv exec ruby bin/rails db:prepare
RBENV_VERSION=3.4.9 rbenv exec bundle exec ./bin/test unit
RBENV_VERSION=3.4.9 rbenv exec bundle exec ./bin/test all
RBENV_VERSION=3.4.9 rbenv exec ruby bin/rails zeitwerk:check
```

`bin/test` はbashスクリプト。`rbenv exec ruby bin/test` や
`rbenv exec bash bin/test` ではなく、上記のBundler経由で起動する。
依存関係の初回確認は `RBENV_VERSION=3.4.9 rbenv exec bundle check`。
足りなければ同じRubyで `bundle install` する（lockfileは維持）。
テスト出力を `tail` / `tee` へ渡すなら `set -o pipefail` で終了コードを保持する。
複数コマンドの最後が成功したことだけで合格にせず、Smartestの失敗・skip件数も確認する。

## worktree用の一時DB

既存の開発DB・別レーン・productionの接続を流用せず、必要ならDockerでテスト用サービス
だけを起動する。アプリ本体やAI CLIのコンテナをbuildする必要はない。
以下はローカル専用の合成パスワードを使う例。tagを担当Issueにし、未使用のportを選ぶ。
同じDBで並列にintegration suiteを動かさない（fixtureはrollback以外の実commitも使う）。
空きportの確認は `docker ps --format '{{.Names}} {{.Ports}}'` などで行う。
他プロジェクトのcontainerの `Config.Env` やホストの全環境変数を列挙して接続情報を探さず、
自分で作ったテストサービスの明示的な `TEST_*` 接続だけを使う。

```sh
export AICONSHELL_TEST_TAG=aiconshell-issue-N
export AICONSHELL_TEST_PG_PORT=15439
export AICONSHELL_TEST_CH_PORT=18129
docker run --detach --rm --name "${AICONSHELL_TEST_TAG}-pg" \
  -p "127.0.0.1:${AICONSHELL_TEST_PG_PORT}:5432" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=aiconshell_test postgres:17.6-bookworm
docker run --detach --rm --name "${AICONSHELL_TEST_TAG}-ch" \
  -p "127.0.0.1:${AICONSHELL_TEST_CH_PORT}:8123" \
  -e CLICKHOUSE_DB=aiconshell_test -e CLICKHOUSE_USER=aiconshell \
  -e CLICKHOUSE_PASSWORD=aiconshell_ci clickhouse/clickhouse-server:26.8.11.7

export TEST_DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:${AICONSHELL_TEST_PG_PORT}/aiconshell_test"
export TEST_CLICKHOUSE_URL="http://127.0.0.1:${AICONSHELL_TEST_CH_PORT}"
export TEST_CLICKHOUSE_DATABASE=aiconshell_test
export TEST_CLICKHOUSE_USER=aiconshell TEST_CLICKHOUSE_PASSWORD=aiconshell_ci
# standalone EventLog fixtureも同じ専用PGへ向ける
export TEST_PG_HOST=127.0.0.1 TEST_PG_PORT="$AICONSHELL_TEST_PG_PORT"
export TEST_PG_DBNAME=aiconshell_test TEST_PG_USER=postgres TEST_PG_PASSWORD=postgres
export RAILS_ENV=test

docker exec "${AICONSHELL_TEST_TAG}-pg" pg_isready -U postgres -d aiconshell_test
curl --fail --silent --show-error "$TEST_CLICKHOUSE_URL/ping"
# 起動直後で未準備なら短く待って上のreadiness確認を再実行する
RBENV_VERSION=3.4.9 rbenv exec ruby bin/rails db:prepare
RBENV_VERSION=3.4.9 rbenv exec bundle exec ./bin/test all
```

Rails wiringの変更はZeitwerkも確認する。対象を絞るときは例えば
`RBENV_VERSION=3.4.9 RAILS_ENV=test rbenv exec bundle exec smartest smartest/integration/admin`。
ClickHouseと無関係な対象テストだけならPGのみでよいが、全suiteの完全検証とは報告しない。
終わったら **自分が作った上記2コンテナだけ** を
`docker stop "${AICONSHELL_TEST_TAG}-pg" "${AICONSHELL_TEST_TAG}-ch"` で片付ける。
他レーンのコンテナやvolumeの一括pruneはしない。

## 境界フィクスチャ

方針は「境界だけを差し替え、検証対象の内部サービスは実物を使う」である。
実プラグインの `Registry`/`Github`/`Teams` には記録用トランスポートを注入し、
業務サービスの深いモックは避ける。単独スイート用ヘルパー
（`ai/ai_test_helper.rb`、`plugins/plugins_test_helper.rb`）を汎用ヘルパーに
取り込まず、各テストは独立した fixture 登録を保つ。

### HttpTransport

```ruby
transport = BoundaryFixtures::HttpTransport.new
url = "https://api.example.test/items"
transport.expect_json(:GET, url, body: { "items" => [] })
response = transport.request(method: "GET", url: url)
expect(response.json).to eq({ "items" => [] })
expect(transport.requests_to(url, method: :GET).size).to eq(1)
transport.assert_consumed!
```

アダプターのテストでは、合成の認証設定を用意した
`Aiconshell::Plugins::Registry.new(env: fixture_env, transport: transport)` に
実アダプターを登録し、Registry 経由で呼び出す。認証交換の HTTP 応答も明示的に用意する。

- `expect_json`/`expect_response`/`expect_error` は有限の method+URL 期待であり、
  エンドポイント間で順序を強制せず、同一エンドポイント内は登録順に応答する。
- `requests`/`requests_to` と `assert_consumed!` で、余分・想定外（rescue 済み含む）
  および未消費スクリプトを検出する。各テストは必ず `assert_consumed!` する。
- 応答は実 `Http::Response`、`raise_for_status!` も実物なので型付き失敗が保たれる。
  失敗メッセージでは URL の query/fragment を除去し、正規表現の内容・ヘッダー・本文は出さない。

### ScriptedProcessRunner と with_ai

```ruby
BoundaryFixtures.with_ai(answers: [{ "priority" => "high" }]) do |ai|
  schema = {
    "type" => "object", "required" => ["priority"], "additionalProperties" => false,
    "properties" => { "priority" => { "type" => "string", "enum" => ["high", "low"] } }
  }
  answer = ai.runner.call(provider: "claude", prompt: "triage", schema: schema,
    workspace: ai.workspace, layer: "coordination")
  expect(answer).to eq({ "priority" => "high" })
  ai.process_runner.assert_consumed!
end
```

- `ScriptedProcessRunner` は Hash・Proc・実 `Ai::Result`・例外を受け付け、`enqueue`
  で後から追加できる。プロセス呼び出しは不変スナップショットで記録される。
- `with_ai` は実 `Runner`/`Registry`/`Config` を返し、合成の絶対実行ファイル・
  認証ホーム・専用 workspace を与える。差し替えはプロセス境界だけで、
  実アダプタ解析とスキーマ検証は有効のままである。
- Proc は凍結済み呼び出し記録を受け取り、Hash・`Ai::Result`・例外を返す。
  不正な戻り値や未消費スクリプトは `assert_consumed!` で失敗する。

## 受け入れアサーション指針

`integration/acceptance/request_workflow_test.rb` と
`request_workflow_failures_test.rb` は、実コントローラ受付 → durable event →
Coordination → GitHub 取得 → 設定済み AI Runner の判断 → 永続送信意図 →
Teams 配送 → 完了確認を通す。`request_acceptance_helper.rb` は一時 Bot 対応表、
合成認証、実 Registry / Github / Teams と境界フィクスチャを組み合わせる。
AI の応答は脚本であり、実モデルの判断品質を保証するテストではない。

UI の Basic 認証と実 CSRF、API の重複受付、通知不要時の無送信、
部分取得・切り詰め情報、AI スキーマ拒否、許可外宛先、未知・重複タスク参照の
全件拒否、GitHub 429、配送の一部失敗と未処理フィードバックを検証する。
実プロバイダ・GitHub / Teams アカウントへ接続することはない。

DB フィクスチャはテストごとに rollback する。受付の
`after_all_transactions_commit` による EventLog・enqueue はそこで発火しないため、
受け入れシナリオでは Coordination を明示的に呼ぶ。
実 commit / rollback と受付後 enqueue の関係は
`integration/admin/task_request_race_test.rb` が別途検証する。

- 永続化された状態、有意な境界リクエスト、未送信であること、スキーマ拒否、
  部分結果メタデータ、成功済み重複の抑止を検証する。
- 正確なプロンプト文面や呼び出し順序は、安全契約でない限り固定しない。
- OAuth/トークン取得の POST と、外部可視の Teams 書き込みは区別する。
  後者は activity 書き込み URL への `requests_to` で数える。
- 想定外呼び出しが rescue されても黙って通過させないため、
  新規テストは HTTP・AI の両スクリプト消費を必ずアサートする。
