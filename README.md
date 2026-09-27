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
# .env の ADMIN_USERNAME / ADMIN_PASSWORD を設定する
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
cp .env.example .env   # 初回のみ。DB / ClickHouse の URL をホスト側のポートへ変更
bin/setup --skip-server  # bundle + development/test 両 DB の db:prepare
bin/dev                  # web（Puma, port 3000）
bin/jobs --mode=async    # Solid Queue 監視（macOS は async 必須。下記注意）
```

- ホスト上で AI を実行する場合は `AICONSHELL_EXECUTION_ROOT` をリポジトリ外の
  書き込み可能な絶対パスにし、AI のホーム・実行ファイルのパスもホスト用に設定する。
  Compose の `/private/*` volume はホストの CLI からは参照できない。
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
| `ADMIN_USERNAME/ADMIN_PASSWORD` | 管理画面の Basic 認証 | 未設定では fail closed |
| `ADMIN_API_TOKEN` | JSON 管理 API（`/api/admin/task_requests`）の Bearer 認証（[docs/task-requests.md](docs/task-requests.md)） | 未設定では fail closed |
| `AICONSHELL_EXECUTION_ROOT` | AI 作業領域ルート（production 必須） | compose は `/workspaces` volume |
| `AICONSHELL_ALLOWED_SCOPES` | 取り込み/送信対象の `plugin:scope` 一覧 | 空（何も対象にしない） |
| `AICONSHELL_LEASE_SECONDS` / `AICONSHELL_AI_TIMEOUT_SECONDS` | 実行 lease / AI 実行上限（lease > timeout + 10 が必須） | `1800` / `600` |
| `RAILS_MAX_THREADS` | Puma + DB プール | `5` |
| `JOB_CONCURRENCY` | `bin/jobs` の worker プロセス数 | `1` |

## 自然言語で依頼する

管理画面の「タスク依頼を作成する」、または管理 API から依頼できる。例:

> owner/repo の未完了 Issue を確認し、障害の影響とラベルから優先度を判断してください。
> 緊急の Issue があれば Teams の指定チャネルへ要約を送り、なければ通知せず結果を残してください。
> 取得範囲が一部なら、その範囲を要約に明記してください。

整理層の AI ポリシーを有効にし、provider・model・effort を設定する。
選んだ CLI の公式サブスクリプション認証、専用 AI 作業領域、
起動中の control worker が必要。未設定 provider も選択できるが、実行時に
分類済みエラーをタスク詳細と受付 API に表示する。API キー課金へは切り替えない。

連携には次の設定が必要（秘密値は private 環境変数・ファイルで渡す）:

- UI は `ADMIN_USERNAME` / `ADMIN_PASSWORD`、API は別の `ADMIN_API_TOKEN`。
- GitHub App の `GITHUB_APP_ID` / `GITHUB_INSTALLATION_ID` と
  `GITHUB_PRIVATE_KEY` または `GITHUB_PRIVATE_KEY_FILE`。
  権限は [GitHub 設定](plugins/github/README.md) を参照。
- Teams の tenant / app / Bot 認証、実際の `TEAMS_SERVICE_URL` と
  `TEAMS_BOT_TARGETS_FILE`。Bot を対象へ導入し、実際の conversation 参照を
  [Teams 設定](plugins/teams/README.md) に従って対応付ける。対応表は自動生成しない。
- 許可対象の例は
  `AICONSHELL_ALLOWED_SCOPES=github:owner/repo,teams:team/TEAM_ID/channel/CHANNEL_ID`。
  Teams 送信入力の宛先は `channel:TEAM_ID/CHANNEL_ID` である。

サーバーに設定したトークンを手元の `ADMIN_API_TOKEN` に設定して実行する:

```sh
curl -i -X POST http://127.0.0.1:3000/api/admin/task_requests \
  -H "Authorization: Bearer $ADMIN_API_TOKEN" \
  -H "Content-Type: application/json" \
  -H "Idempotency-Key: open-issues-review-001" \
  --data-binary @- <<'JSON'
{"title":"未完了Issueの確認","description":"owner/repoの未完了Issueを確認し、緊急ならTeamsのchannel:TEAM_ID/CHANNEL_IDへ要約を送ってください。なければ通知せず、取得範囲も結果に残してください。"}
JSON

# POST の request_id を設定する（Idempotency-Key とは別のサーバー発行 UUID）
REQUEST_ID='POSTで返されたrequest_id'
curl -sS "http://127.0.0.1:3000/api/admin/task_requests/$REQUEST_ID" \
  -H "Authorization: Bearer $ADMIN_API_TOKEN"
```

`202` は受付済みを表す。同じキー・同じ内容の再送は同じ受付になり、
異なる内容では `409` になる。受付の `status` は `accepted` / `processed`、
処理状態は別の `task_status` で確認する。通知を起案すると `waiting_delivery`、
全送信確認後に `done`、失敗・送信結果不明は `waiting_human` になる。
結果は `coordination_result` の要約・通知件数と `last_error` で確認できる。
通知が不要なら送信せず `done` になる。

利用可能なのは宣言済み操作と許可済み宛先だけ。GitHub 取得は 1 回最大 30 件、
AI の読み取りは 1 回の調整処理で最大 3 ラウンド・計 10 回で、本文切り詰めや続きの有無も
判断に渡すため、部分取得を全件調査と同一視しない。
成功確認済みの重複配送は抑止するが、外部送信直後のクラッシュや応答不明を含む
完全な一回配送は保証しない。詳細は [受付 API](docs/task-requests.md) と
[ワークフロー](docs/workflow.md) を参照。

## テスト

```sh
bin/test unit                  # DB なし全 suite（unit/plugins/ai）
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
- 境界フィクスチャ、単体と実 DB の使い分け、受け入れテストの実行方法は
  [docs/testing.md](docs/testing.md) を参照。

## 操作・デプロイ

- 日常操作・AI CLI 導入・Railway・ngrok は [docs/deployment.md](docs/deployment.md)。
- 共有 PostgreSQL サーバー上の複数利用環境は
  [docs/railway-environments.md](docs/railway-environments.md)。
- イメージは役割別: web は常に CLI なしの `app`、worker は `ai` が既定
  （Claude/Codex/Muse 付き。Muse は公式公開 Linux バイナリを固定
  バージョン・SHA256 検証で同梱）。認証ログインは別の実行時手順。
- 環境変数は `.env.example` が正。`execution` worker には連携資格情報を
  渡さない（compose と AI 層の両方で遮断）。
- ClickHouse は結果整合性のため分離起動する: 障害時も web/worker は
  起動し、配信は outbox に滞留してリトライされる。スキーマ適用は
  `clickhouse-init`（compose）/ 別途 one-off（Railway）で行う。
- AI のサブスクリプションログインは管理画面の「AI連携」から worker 別に行う
  （[docs/ai-connections.md](docs/ai-connections.md)）。control と execution
  は別 volume のため両方へのログインが要る。未連携 provider も選択可。

## 構成

- `app/` — Rails 8（Puma・Thruster、CSRF/CSP 既定）。`ApplicationJob` /
  `ApplicationRecord` は基底クラス。ドメイン別詳細は各 docs 参照。
- `config/queue_control.yml` / `config/queue_execution.yml` — 本番用
  worker 分割設定（`config/queue.yml` は開発用一括）。
- `lib/aiconshell/{plugins,ai,observability}/` — 明示 require の pure
  Ruby ポート（Zeitwerk 対象外）。
- `smartest/` — `unit/`（`observability/` 含む）・`plugins/`・`ai/`（DB なし）、
  `integration/`（`observability/` 含む、実 DB）。
- `compose.yml`・`Dockerfile`・`railway*.toml`・`bin/smoke`・
  `bin/setup-clickhouse`・`bin/check-compose` — 運用配線（issue #8）。

## 検証範囲

本リポジトリで自動確認できる範囲と、運営者作業の範囲を分ける:

- 自動確認: `docker compose config`、上記テスト群、`./bin/smoke`、
  `app`/`ai` イメージビルド、`app` の CLI 不在、pinned CLI の Linux `--version`、
  定期実行 6 件の登録・消費、管理画面の認証挙動、EventLog の実
  ClickHouse 配送、ClickHouse 停止中の起動継続と復帰後配送、
  本番同等 `/up` の redirect 除外（詳細は `docs/deployment.md` §10）。
- 運営者作業（要アカウント）: Railway 実デプロイ、ngrok 実公開、各 CLI
  のサブスクリプションログイン、実サービスへの投稿・取得。
