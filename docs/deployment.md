# デプロイ・運用手順

ローカル Compose と Railway で同じ分割（web / control worker / execution
worker / PostgreSQL / ClickHouse）を使うための手順書。全体設計は
[docs/architecture.md](architecture.md) を参照。

## 1. 構成

| サービス | 役割 | キュー | 資格情報 |
| --- | --- | --- | --- |
| `web` | 管理画面・Webhook 受付 | — | DB・ClickHouse・連携資格情報 |
| `control` | ポーリング・振分・配信・定期実行 | `control` のみ | DB・ClickHouse・連携資格情報・AI auth |
| `execution` | AI CLI 実行（隔離 workspace） | `execution` のみ | DB・AI auth のみ |
| `migrate` | 初期セットアップ専用（使い捨て） | — | DB・ClickHouse |
| `db` | PostgreSQL 17（Solid Queue 同居） | — | — |
| `clickhouse` | EventLog 検索（26.8 系） | — | — |
| `ngrok` | 任意トンネル（profile 加入時のみ） | — | トークンのみ |

境界の要点:

- Web と両 worker は**同一 `DATABASE_URL`**（1 DB・キュー分離）。
  キュー分離は `config/queue_control.yml` /
  `config/queue_execution.yml` + `--config-file` で行う（Solid Queue の CLI
  に `--queues` は無い）。定期実行スケジューラは control のみ
  （execution は `--skip-recurring`）。
- `execution` に GitHub / Jira / Teams / ClickHouse の資格情報を渡さない。
  `bin/check-compose` が compose 上で検証し、AI 層
  （`lib/aiconshell/ai/child_env.rb`）が子プロセスにも継承させない。
- マイグレーションは `migrate` サービスの1プロセスのみ
  （`AICONSHELL_RUN_SETUP=1`）。web/worker の起動時は実行しない。
- AI の資格情報・バイナリ欠如は web 起動を止めない（未設定 provider は
  選択可・実行時失敗が契約）。
- Docker ソケットはどのコンテナにもマウントしない。

## 2. ローカル起動（Compose）

前提: Docker（Compose v2）、Ruby 3.4.9
（`RBENV_VERSION=3.4.9 rbenv exec ...`）。

```sh
cp .env.example .env   # 初回のみ。COMPOSE_PROJECT_NAME は checkout 毎に変更
docker compose up --build
./bin/smoke            # 別ターミナル、または -d 起動後に実行
```

- ポートは既定で loopback 束縛: web 3000、PostgreSQL 5432、ClickHouse
  8123。`WEB_PORT` / `POSTGRES_PORT` / `CLICKHOUSE_PORT`（+ `*_BIND`）で
  変更できる。既定の開発用資格情報のまま `0.0.0.0` 束縛にしないこと。
- コードはイメージ内蔵（ソースの bind mount なし）。pull 後の更新は
  `docker compose up --build` で取り込む。
- `docker compose down -v` は DB・ClickHouse・AI auth を含む全 volume を
  消す。AI の再ログインが必要になる点に注意。
- 本番同等（`RAILS_ENV=production` + Thruster）の確認手順は「8. 検証」
  参照。既定の `development` では `/up` ヘルスチェックがそのまま動く。

## 3. テスト

```sh
bin/test unit                        # DB・外部通信・AI なし
RAILS_ENV=test bin/rails db:prepare  # 初回のみ（統合用 DB 作成）
bin/test integration                 # 実 PostgreSQL（TEST_DATABASE_URL）
bin/rails zeitwerk:check             # autoload 検査
ruby bin/check-compose               # compose/queue/Dockerfile/CI の静的検査
./bin/smoke                          # 起動中スタックの live 確認
./bin/setup-clickhouse               # ClickHouse スキーマ適用（単体実行可）
```

`bin/test` は存在しない suite を警告付きで skip する（レーン結合途中の
移行措置。suite 追加後は通常通り必須）。CI では unit / integration を
別 job で実行する。

## 4. AI CLI プロビジョニング

`Dockerfile` の `ai` ターゲットが CLI 付き worker イメージを作る。
既定（`app`）には CLI を含めない。

| CLI | 導入元 | 既定バージョン（ARG で上書き可） |
| --- | --- | --- |
| Node.js | 公式 tarball（x64/arm64） | `NODE_VERSION=24.21.0`（LTS） |
| `claude` | npm `@anthropic-ai/claude-code` | `CLAUDE_CODE_VERSION=2.1.283` |
| `codex` | npm `@openai/codex` | `CODEX_VERSION=0.157.1` |
| `muse` | 運営者支給の Linux バイナリ（要認証配布） | ビルドシークレットで注入 |

```sh
# 基本イメージ
docker build -t aiconshell:app .
# CLI 付き（muse 抜きでもビルド可。その場合 muse は実行時失敗扱い）
docker build --target ai -t aiconshell:ai .
# muse を含める場合（ホストの macOS バイナリや資格情報は使わない。
# 正規の Linux バイナリをリポジトリ外に置き、シークレットで渡す）
docker build --target ai -t aiconshell:ai \
  --secret id=muse_cli,src=$HOME/.cache/aiconshell/muse-cli/muse .
```

worker に CLI イメージを使わせるには `.env` で切り替える:

```sh
CONTROL_TARGET=ai
EXECUTION_TARGET=ai
```

認証ホーム（AI 層 `Config` と同一契約）:

| provider | コンテナ内 env | マウント先 volume |
| --- | --- | --- |
| claude | `CLAUDE_CONFIG_DIR=/private/claude` | `claude_auth` |
| codex | `CODEX_HOME=/private/codex` | `codex_auth` |
| muse | `MUSE_CONFIG_DIR=/private/muse` | `muse_auth` |

volume は uid 1000（`rails`）で書けるよう image 側で用意済み。通常の
CLI トークン更新が volume に永続化される。サブスクリプションのログイン
自体は運営者作業（worker コンテナに入り、各 CLI の公式ログインフローで
認証する。CI・テストでは一切行わない）:

```sh
docker compose run --rm -it execution bash
# コンテナ内で: claude login / codex login 等の公式フロー
```

## 5. Railway

実デプロイは運営者作業。構成は Compose と同じ分割にする。

1. 同一プロジェクト・環境に 3 サービス（同リポジトリ）+ PostgreSQL
   プラグイン + ClickHouse テンプレートを用意する。
2. `railway.toml`（本リポジトリ直下）は **web 用**。control / execution
   はダッシュボードで以下を上書きする:

   | サービス | startCommand | predeploy | healthcheck |
   | --- | --- | --- | --- |
   | web | `./bin/thrust ./bin/rails server`（既定） | `./bin/rails db:prepare && ./bin/setup-clickhouse` | `/up` |
   | control | `./bin/jobs --config-file=config/queue_control.yml` | （空） | なし |
   | execution | `./bin/jobs --config-file=config/queue_execution.yml --skip-recurring` | （空） | なし |

3. 環境変数（`Service Variables` の参照を使う）:

   | 変数 | 値の例 |
   | --- | --- |
   | `DATABASE_URL` | `${{Postgres.DATABASE_URL}}`（3 サービス共通） |
   | `CLICKHOUSE_URL` | `http://${{ClickHouse.RAILWAY_PRIVATE_DOMAIN}}:8123` |
   | `CLICKHOUSE_DATABASE/USER/PASSWORD` | ClickHouse サービスの値 |
   | `SECRET_KEY_BASE` | `bin/rails secret` で生成（必須） |
   | `ADMIN_USERNAME/ADMIN_PASSWORD` | 管理画面用（必須、未設定は fail closed） |
   | `RAILS_ENV` | `production` |
   | 連携資格情報 | control・web のみ（execution には設定しない） |

4. Private networking を使い、DB・ClickHouse の公開ポートは開けない。
5. Volume を control・execution に追加し、`/private/claude`・
   `/private/codex`・`/private/muse` にマウントする（web は不要）。
6. `PORT` は Railway が注入する（Thruster・Puma が参照）。固定しない。
7. CLI 付き worker は、CI 等で `ai` ターゲットをビルドしてレジストリに
   push し、そのイメージを control・execution サービスに指定する
   （Railway の Dockerfile ビルドは既定 `app` のため）。

## 6. ngrok（明示 opt-in）

通常は不要（外部取得はポーリングのため）。Webhook デモ等でのみ使う:

```sh
NGROK_AUTHTOKEN=... docker compose --profile tunnel up ngrok
# 管理 UI: http://127.0.0.1:4040（NGROK_PORT で変更可）
```

注意:

- 公開 URL は起動ログ・管理 UI で確認し、使う相手にだけ共有する。
- Rails の Host 認可に公開ホストの許可が必要。`config.hosts` は
  Rails 基盤（#2）の管理ファイルのため、トンネル利用時は基盤側の設定に
  公開ホストの追加が必要（本手順書を基盤レーンとの契約とする）。
- トークンは `.env`（git 管理外）のみ。CI・イメージに混入しない。

## 7. CI

`.github/workflows/ci.yml`（テスト専用。GitHub Actions を実行基盤・
スケジューラには使わない）:

| job | 内容 |
| --- | --- |
| `unit` | Smartest unit（DB なし） |
| `integration` | Smartest integration（PostgreSQL サービス + `TEST_DATABASE_URL`） |
| `zeitwerk` | `bin/rails zeitwerk:check` |
| `ops` | `docker compose config`、`ruby bin/check-compose`、`app`/`ai` ビルド |
| `clickhouse-smoke` | 実 ClickHouse サービス + `./bin/setup-clickhouse` |

CI は live provider・実アカウント・資格情報を一切使わない。AI イメージ
のビルドもログインなし（`muse` はシークレット無しで skip される）。

## 8. 検証

### 8.1 オフライン／コンテナで確認する範囲

- `docker compose config`、`ruby bin/check-compose` が通る。
- `docker compose up --build` 後、`./bin/smoke` が全件 ok
  （web `/up`、PostgreSQL、ClickHouse `event_log`、両 worker 起動、
  `DATABASE_URL` 一致）。
- `bin/test unit` / `bin/test integration` /
  `bin/rails zeitwerk:check` が通る。
- `docker build .`（既定 `app`）と `docker build --target ai .` が成功する。
- 本番同等起動の確認（任意）:
  `RAILS_ENV=production SECRET_KEY_BASE=$(bin/rails secret) docker compose up --build`
  後に `./bin/smoke`。`/up` が `force_ssl` で redirect される場合は
  ヘルスチェックの調整が必要（既定開発起動では不要）。

### 8.2 運営者アカウントが必要な範囲（自動検証しない）

- Railway への実デプロイ・実ドメイン公開。
- ngrok の実公開・外部 Webhook 受信。
- 各 CLI のサブスクリプションログイン・トークン更新。
  （`muse` Linux バイナリの入手を含む）
- 実 GitHub / Jira / Teams への投稿・取得。

## 9. トラブルシュート

- ポート衝突: `.env` の `WEB_PORT` / `POSTGRES_PORT` /
  `CLICKHOUSE_PORT` を空きポートに変えて `docker compose up` し直す。
- ClickHouse の初回起動は遅い（数十秒）。`migrate` はヘルスチェック通過
  を待つため、そのまま待つ。
- `migrate` 失敗時: `docker compose logs migrate` を見て直し、
  `docker compose up migrate` で再実行（冪等）。
- AI トークン期限切れ: 該当 volume を消さず「4.」の手順で再ログインする
  （volume を消すと再ログイン必須）。
- 他 worktree との volume 衝突: `COMPOSE_PROJECT_NAME` が checkout 毎に
  異なることを確認する。
