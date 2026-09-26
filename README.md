# aiconshell

AI エンジニア基盤。外部サービス（GitHub / Jira / Teams）のイベントを
取り込み、タスク化・優先度付け・AI 実行し、結果を EventLog に残す。
設計は [docs/architecture.md](docs/architecture.md)、運用手順は
[docs/deployment.md](docs/deployment.md)。

## 要件

- Docker（Compose v2）— コンテナ起動用
- Ruby 3.4.9（`rbenv`。`.ruby-version` 参照）
- PostgreSQL 16+（ローカル実行時。コンテナ起動なら compose が用意）
- Node/JS ツールチェイン不要（素の Propshaft CSS + ERB）

## 起動（5分・コンテナ）

```sh
cp .env.example .env   # 初回のみ。COMPOSE_PROJECT_NAME は checkout 毎に変更
docker compose up --build
./bin/smoke            # 別ターミナルで確認（web・DB・ClickHouse・worker）
```

開く: http://127.0.0.1:3000（`WEB_PORT` で変更可。`/up` がヘルスチェック、
`/` がランディング、`/admin` が管理画面）。

コードはイメージ内蔵のため、pull・編集後の取り込みは毎回
`docker compose up --build` で行う（自動ホットリロードは無い）。
速く回したい内側ループは下のローカル実行を使う。

## 開発ループ（ローカル実行）

```sh
cp .env.example .env   # 初回のみ。DATABASE_URL / TEST_DATABASE_URL を設定
bin/setup --skip-server  # bundle + development/test 両 DB の db:prepare
bin/dev                  # web（Puma, port 3000）
bin/jobs --mode=async    # Solid Queue 監視（macOS は async 必須。下記注意）
```

- `.env` は compose が読むほか、ローカル実行では dotenv-rails 経由で
  development/test に読まれる（`.env` 自体は git 管理外）。
- `bin/jobs` の既定 fork モードは Linux Docker 用。macOS の fork worker
  は不安定（pg ネイティブ拡張 + ObjC ランタイムの fork 安全性）のため、
  macOS ローカルでは必ず `--mode=async` を付ける。
- 本番用ワーカー分割（control / execution の `--config-file` 指定）は
  compose と Railway で行う（[docs/deployment.md](docs/deployment.md)）。
  ローカルの `bin/jobs`（無引数）は全キューの開発用一括起動である。

主な環境変数（全量は `.env.example` が正）:

| 変数 | 用途 | 既定 |
| --- | --- | --- |
| `DATABASE_URL` | development・production の単一 DB（Solid Queue 同居） | dev のみ localhost 既定。production は必須 |
| `TEST_DATABASE_URL` | integration suite 用（`*_test` 必須） | `DATABASE_URL`、無ければ localhost の `_test` |
| `SECRET_KEY_BASE` | Rails secret | compose は開発用ダミー。共有環境では必須 |
| `ADMIN_USERNAME/ADMIN_PASSWORD` | 管理画面の Basic 認証 | 未設定の production は fail closed |
| `AICONSHELL_EXECUTION_ROOT` | AI 作業領域ルート（production 必須） | compose は `/workspaces` volume |
| `AICONSHELL_ALLOWED_SCOPES` | 取り込み/送信対象の `plugin:scope` 一覧 | 空（何も対象にしない） |
| `AICONSHELL_LEASE_SECONDS` / `AICONSHELL_AI_TIMEOUT_SECONDS` | 実行 lease / AI 実行上限（lease > timeout + 10 が必須） | `1800` / `600` |
| `RAILS_MAX_THREADS` | Puma + DB プール | `5` |
| `JOB_CONCURRENCY` | `bin/jobs` の worker プロセス数 | `1` |

## テスト

```sh
bin/test unit                  # DB なし全 suite（unit/plugins/ai/observability）
bin/test integration           # 結合（実 PostgreSQL + 実 ClickHouse）
bin/rails zeitwerk:check       # autoload 検査
ruby bin/check-compose         # compose・queue・CI の静的検査
```

- `bin/test` は全 `smartest/**/*_test.rb` の suite 登録を検査し、漏れが
  あれば失敗する。CI（`.github/workflows/ci.yml`）はテスト専用で、
  上記＋イメージビルド＋実 ClickHouse 機構確認を行う。
- integration は初回に `RAILS_ENV=test bin/rails db:prepare` が要る。
  `TEST_CLICKHOUSE_URL` を明示した場合は到達を事前確認し、応答が
  なければ沈黙 skip せず即失敗する。
- live provider・実アカウントは使わない。pinned CLI の Linux
  `--version` 確認は自動化するが、サブスクリプションのログインは
  運営者作業であり自動検証しない（「検証範囲」参照）。

## 操作・デプロイ

- 日常操作・AI CLI 導入・Railway・ngrok は [docs/deployment.md](docs/deployment.md)。
- 環境変数は `.env.example` が正。`execution` worker には連携資格情報を
  渡さない（compose と AI 層の両方で遮断）。
- ClickHouse は結果整合性のため分離起動する: 障害時も web/worker は
  起動し、配信は outbox に滞留してリトライされる。スキーマ適用は
  `clickhouse-init`（compose）/ 別途 one-off（Railway）で行う。

## 構成

- `app/` — Rails 8（Puma・Thruster、CSRF/CSP 既定）。`ApplicationJob` /
  `ApplicationRecord` は基底クラス。ドメイン別詳細は各 docs 参照。
- `config/queue_control.yml` / `config/queue_execution.yml` — 本番用
  worker 分割設定（`config/queue.yml` は開発用一括）。
- `lib/aiconshell/{plugins,ai,observability}/` — 明示 require の pure
  Ruby ポート（Zeitwerk 対象外）。
- `smartest/` — `unit/`・`plugins/`・`ai/`・`observability/`（DB なし）、
  `integration/`（実 DB）。
- `compose.yml`・`Dockerfile`・`railway.toml`・`bin/smoke`・
  `bin/setup-clickhouse`・`bin/check-compose` — 運用配線（issue #8）。

## 検証範囲

本リポジトリで自動確認できる範囲と、運営者作業の範囲を分ける:

- 自動確認: `docker compose config`、上記テスト群、`./bin/smoke`、
  `app`/`ai` イメージビルド、pinned CLI の Linux `--version`、
  ClickHouse 機構確認（probe スキーマ適用）。
- 運営者作業（要アカウント）: Railway 実デプロイ、ngrok 実公開、各 CLI
  のログイン（`muse` バイナリ入手含む）、実サービスへの投稿・取得。
