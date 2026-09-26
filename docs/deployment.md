# デプロイ・運用手順

ローカル Compose と Railway で同じ分割（web / control worker / execution
worker / PostgreSQL / ClickHouse）を使うための手順書。全体設計は
[docs/architecture.md](architecture.md) を参照。

## 1. 構成

| サービス | 役割 | キュー | 環境変数 |
| --- | --- | --- | --- |
| `web` | 管理画面 | — | DB・ワークフロー設定・EventLog 既定チャネル・ClickHouse・連携資格情報 |
| `control` | ポーリング・振分・配信・定期実行・coordination AI | `control` のみ | DB・ワークフロー設定・EventLog 既定チャネル・ClickHouse・連携資格情報・自アクタ・AI auth |
| `execution` | AI CLI 実行（隔離 workspace） | `execution` のみ | DB・ワークフロー設定・EventLog 既定チャネル・AI auth のみ |
| `migrate` | SQL マイグレーション専用（使い捨て） | — | DB・ワークフロー設定・EventLog 既定チャネル |
| `clickhouse-init` | ClickHouse スキーマ適用（使い捨て・独立） | — | ClickHouse のみ |
| `db` | PostgreSQL 17（Solid Queue 同居） | — | — |
| `clickhouse` | EventLog 検索（26.8 系） | — | — |
| `ngrok` | 任意トンネル（profile 加入時のみ） | — | トークンのみ |

境界の要点:

- Web と両 worker は**同一 `DATABASE_URL`**（1 DB・キュー分離）。
  キュー分離は `config/queue_control.yml` /
  `config/queue_execution.yml` + `--config-file` で行う（Solid Queue の CLI
  に `--queues` は無い）。定期実行スケジューラは control のみ
  （execution は `--skip-recurring`）。実際の `queue_as` 宣言と一致:
  control 系 job（poll / triage / outbound / lease 回復 / EventLog 配信 /
  maintenance）は `:control`、実行 job は `:execution`。
- `execution` に GitHub / Jira / Teams / ClickHouse の資格情報を渡さない。
  `bin/check-compose` が compose 上で検証し、AI 層
  （`lib/aiconshell/ai/child_env.rb`）が子プロセスにも継承させない。
  `EVENT_LOG_TEAMS_CHANNEL`（既定チャネル名。空が既定）は資格情報では
  ないため全 Rails プロセスに渡す。`TEAMS_BOT_TARGETS_FILE` はパス指定
  のみ web・control に渡し、実ファイルは運営者が read-only マウントする
  （「6. 資格情報ファイルのマウント」参照）。
- マイグレーションは `migrate` サービスの1プロセスのみ
  （`AICONSHELL_RUN_DB_SETUP=1`）。web/worker の起動時は実行しない。
- EventLog は結果整合性: ClickHouse 障害は起動を止めない。web/worker は
  ClickHouse に依存せず、`clickhouse-init` が独立にスキーマ適用する。
  適用までの配信は PostgreSQL の outbox に滞留し、リトライされる。
- AI の資格情報・バイナリ欠如は web 起動を止めない（未設定 provider は
  選択可・実行時失敗が契約）。
- 管理画面の provider 診断バッジは web コンテナ内のローカル表示専用
  （「12. Provider 診断は web ローカル」参照）。worker 側の真実は
  `docker compose exec control|execution` で確認する。
- Docker ソケットはどのコンテナにもマウントしない。

## 2. 定期実行

`config/recurring.yml` が development・production 共通のスケジュールを持つ
（test は自動実行しない）。スケジューラは control worker のみが動かし、
execution worker は `--skip-recurring` で起動するため二重登録しない。
全タスクがキュー `control` 宛てで、control worker が消費する。

| タスク | ジョブ | スケジュール |
| --- | --- | --- |
| `integration_poll_schedule` | `IntegrationPollScheduleJob`（引数なし） | 5 分毎 |
| `coordination_triage` | `CoordinationTriageJob` | 毎分 |
| `lease_recovery` | `LeaseRecoveryJob` | 毎分 |
| `workflow_maintenance` | `WorkflowMaintenanceJob` | 毎分 |
| `event_log_delivery` | `EventLogDeliveryJob` | 毎分 |
| `clear_solid_queue_finished_jobs` | 完了済みジョブ掃除（コマンド） | 毎時 12 分 |

注意:

- 掃除コマンドにも `queue: control` を明示している。付けないと
  Solid Queue 既定の `solid_queue_recurring` キューに積まれ、
  どの worker も拾わない。
- ジョブ側の `queue_as :control` 宣言と一致すること、
  スケジュール文字列・引数なしを `ruby bin/check-compose` が静的に検査する。
- 稼働中スタックでは `./bin/smoke` が `solid_queue_recurring_tasks` の
  6 件登録を確認する（スケジューラ実体の証跡）。
- test 環境にスケジュールは無い。suite はジョブを明示的に enqueue する。

## 3. ローカル起動（Compose）

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
  `docker compose up --build` で取り込む。自動ホットリロードは無い:
  速い反復はローカル実行（README「開発ループ」参照）で行う。
- `docker compose down -v` は DB・ClickHouse・AI auth・workspaces を含む
  全 volume を消す。AI の再ログインが必要になる点に注意。
- 本番同等（`RAILS_ENV=production`）の `/up` 挙動は出荷前に確認済み
  （「10. 検証」参照）。`/up` は redirect なく 200 を返し、
  Railway のヘルスチェックがそのまま動く。

## 4. テスト

```sh
bin/test unit                        # DB なし全 suite（unit/plugins/ai）
RAILS_ENV=test bin/rails db:prepare  # 初回のみ（統合用 DB 作成）
bin/test integration                 # 実 PostgreSQL + 実 ClickHouse（TEST_*_URL）
bin/rails zeitwerk:check             # autoload 検査
ruby bin/check-compose               # compose/queue/recurring/Dockerfile/CI の静的検査
./bin/smoke                          # 起動中スタックの live 確認
./bin/setup-clickhouse               # ClickHouse スキーマ適用（単体実行可）
```

`bin/test` は全 `smartest/**/*_test.rb` がいずれか1つの suite root
（unit 系は `smartest/unit`・`smartest/plugins`・`smartest/ai`、
結合は `smartest/integration`）に属することを検査し、属さない
ファイルがあれば一覧して失敗する（新しい suite が runner 未登録の
まま着陸しない）。EventLog の suite は `smartest/unit/observability`
と `smartest/integration/observability` にあり、各 root の再帰展開で
必ず実行される。

`TEST_CLICKHOUSE_URL` を明示したら、integration は先に `/ping` で到達
確認し、応答がなければ即失敗する（ClickHouse 系テストの沈黙 skip を
許さない）。CI の integration job は必ず ClickHouse サービス付きで
実行する。

## 5. AI CLI プロビジョニング

`Dockerfile` の `ai` ターゲットが CLI 付き worker イメージを作る。
既定（`app`）には CLI を含めない。

| CLI | 導入元 | 既定バージョン（ARG で上書き可） |
| --- | --- | --- |
| Node.js | 公式 tarball（x64/arm64） | `NODE_VERSION=24.21.0`（LTS） |
| `claude` | npm `@anthropic-ai/claude-code` | `CLAUDE_CODE_VERSION=2.1.283` |
| `codex` | npm `@openai/codex` | `CODEX_VERSION=0.157.1` |
| `git` | apt（AI の工程コマンド用） | ディストリビューション版 |
| `muse` | 運営者支給の Linux バイナリ（要認証配布） | ビルドシークレットで注入 |

```sh
# 基本イメージ
docker build -t aiconshell:app .
# CLI 付き（muse 抜きでもビルド可。その場合 muse は実行時失敗扱い）
docker build --target ai -t aiconshell:ai .
# muse を含める場合（ホストの macOS バイナリや資格情報は使わない。
# 正規の Linux バイナリをリポジトリ外に置き、シークレットで渡す。
# シークレット有無の切り替え時は --no-cache が必須: BuildKit は
# secret マウント層をキャッシュするため、付けないと古い層が残る）
docker build --target ai --no-cache -t aiconshell:ai \
  --secret id=muse_cli,src=$HOME/.cache/aiconshell/muse-cli/muse .
```

`muse` の取り扱いを正確に述べる: ビルド時の `install` はバイナリを
`/usr/local/bin/muse` に**意図的にコピーし、ai イメージの一部にする**。
ビルド後に消えるのはシークレットのマウント（`/run/secrets/muse_cli`
はレイヤに残らない）だけであり、認証資格情報は常にイメージ外
（マウント volume）に置く。資格情報をリポジトリやイメージに混入
させないこと。

worker に CLI イメージを使わせるには `.env` で切り替える（control も
coordination AI を実行するため、両方とも `ai` が要る）:

```sh
CONTROL_TARGET=ai
EXECUTION_TARGET=ai
```

認証ホーム（AI 層 `Config` と同一契約）:

| provider | コンテナ内 env | マウント先 volume |
| --- | --- | --- |
| claude | `CLAUDE_CONFIG_DIR=/private/claude` | `claude_auth` |
| codex | `CODEX_HOME=/private/codex` | `codex_auth` |
| muse | `AICONSHELL_MUSE_HOME=/private/muse`（XDG home） | `muse_auth` |

muse は XDG 基準: `AICONSHELL_MUSE_HOME` は `muse` ディレクトリを**含む**
ディレクトリを指し、認証は `/private/muse/muse/auth.json` に置かれる。
`MUSE_CONFIG_DIR` という変数は存在しない（native CLI は解釈しない）。
実行子プロセスには `XDG_CONFIG_HOME` + `MUSE_AUTH_PATH` だけが渡る
（`ChildEnv` の契約）。

volume は uid 1000（`rails`）で書けるよう image 側で用意済み。通常の
CLI トークン更新が volume に永続化される。サブスクリプションのログイン
自体は運営者作業（worker コンテナに入り、各 CLI の公式ログインフローで
認証する。CI・テストでは一切行わない）:

```sh
docker compose run --rm -it execution bash
# claude / codex は compose の env がそのまま効く
claude login   # または公式フロー
codex login    # または公式フロー
# muse だけは対話シェルで XDG を明示する（アプリ経由の実行では不要）
export XDG_CONFIG_HOME=$AICONSHELL_MUSE_HOME
muse login     # または公式フロー
```

実行 workspace（`AICONSHELL_EXECUTION_ROOT=/workspaces`）は control・
execution 両方に `ai_workspaces` volume としてマウントされる。アプリ
ソース外の永続領域で、uid 1000 所有。triage の `policy-coordination`
と実行 run の作業ディレクトリがここに作られる。

## 6. 資格情報ファイルのマウント

`GITHUB_PRIVATE_KEY_FILE`・`JIRA_API_TOKEN_FILE`・
`TEAMS_CLIENT_SECRET_FILE`・`TEAMS_BOT_APP_PASSWORD_FILE`・
`TEAMS_BOT_TARGETS_FILE` はコンテナ内パスだけを環境変数で渡す。
実ファイルの内容は compose・Railway・イメージ・Git のいずれにも
入れない。プラグインは値（`GITHUB_PRIVATE_KEY` 等）とファイルの
どちらか片方があれば動き、両方空なら「未設定」として実行時失敗する。

Compose ではホストの private ファイルを対象サービスへ read-only で
bind マウントする（`execution` には絶対に付けない）。
`compose.override.yml`（git 管理外）の例:

```yaml
services:
  web:
    volumes:
      - type: bind
        source: /srv/secrets/aiconshell/teams-bot-targets.json
        target: /run/secrets/teams-bot-targets.json
        read_only: true
  control:
    volumes:
      - type: bind
        source: /srv/secrets/aiconshell/teams-bot-targets.json
        target: /run/secrets/teams-bot-targets.json
        read_only: true
      - type: bind
        source: /srv/secrets/aiconshell/github-app.pem
        target: /run/secrets/github-app.pem
        read_only: true
```

```sh
# .env（git 管理外。パスだけ。内容は書かない）
TEAMS_BOT_TARGETS_FILE=/run/secrets/teams-bot-targets.json
GITHUB_PRIVATE_KEY_FILE=/run/secrets/github-app.pem
```

注意:

- ホスト側ファイルは `chmod 600`・運営者のみ読み取り可にする。
  AI 実行 workspace（`/workspaces`）やリポジトリ内には置かない。
- `TEAMS_BOT_TARGETS_FILE` の JSON 形式は
  `plugins/teams/README.md`「Bot 参照の対応表」が正。
  Graph の team / channel ID と Bot conversation 参照の対応表であり、
  受信済みの実際の参照だけを載せる。自動生成はしない。
- Railway にはホスト bind が無い。資格情報ファイルが必要な場合は
  同内容の volume をサービスに添付して同パスに配置するか、値型の
  環境変数で直接設定する（`TEAMS_BOT_TARGETS_FILE` の JSON は
  volume 配置のみ。未配置なら Teams 送信は実行時失敗する）。

## 7. Railway

実デプロイは運営者作業。構成は Compose と同じ分割にする。

1. 同一プロジェクト・環境に 3 サービス（同リポジトリ）+ PostgreSQL
   プラグイン + ClickHouse テンプレートを用意する。
2. `railway.toml`（本リポジトリ直下）は **web 用**。control / execution
   はダッシュボードで以下を上書きする:

   | サービス | startCommand | predeploy | healthcheck |
   | --- | --- | --- | --- |
   | web | `./bin/thrust ./bin/rails server`（既定） | `./bin/rails db:prepare`（SQL のみ） | `/up` |
   | control | `./bin/jobs --config-file=config/queue_control.yml` | （空） | なし |
   | execution | `./bin/jobs --config-file=config/queue_execution.yml --skip-recurring` | （空） | なし |

   predeploy は SQL マイグレーション専用。ClickHouse スキーマは分離し、
   ClickHouse 到達後に別途 `railway run ./bin/setup-clickhouse`（または
   同等の one-off 実行）で適用する。logging 障害でデプロイを止めない。
3. 環境変数（`Service Variables` の参照を使う）:

   | 変数 | 値の例 |
   | --- | --- |
   | `DATABASE_URL` | `${{Postgres.DATABASE_URL}}`（3 サービス共通） |
   | `CLICKHOUSE_URL` | `http://${{ClickHouse.RAILWAY_PRIVATE_DOMAIN}}:8123` |
   | `CLICKHOUSE_DATABASE/USER/PASSWORD` | ClickHouse サービスの値 |
   | `SECRET_KEY_BASE` | `bin/rails secret` で生成（必須） |
   | `ADMIN_USERNAME/ADMIN_PASSWORD` | 管理画面用（必須、未設定は fail closed） |
   | `RAILS_ENV` | `production` |
   | `EVENT_LOG_TEAMS_CHANNEL` | 既定 Teams チャネル（空が既定。3 サービス共通値） |
   | ワークフロー設定 | `AICONSHELL_EXECUTION_ROOT`（必須）・`AICONSHELL_ALLOWED_SCOPES`・lease/timeout/attempts・`AICONSHELL_DEMO_MODE`（全サービス共通値） |
   | 連携資格情報 | control・web のみ（execution には設定しない。`TEAMS_BOT_TARGETS_FILE` は「6.」の volume 配置） |
   | 自アクタ ID | `AICONSHELL_SELF_ACTOR_IDS`・`JIRA_SERVICE_ACCOUNT_ID`（control のみ） |
   | AI home/bin | `CLAUDE_CONFIG_DIR`・`CODEX_HOME`・`AICONSHELL_MUSE_HOME`・`AICONSHELL_AI_HOME`・`AICONSHELL_*_BIN`（control・execution のみ） |

4. Private networking を使い、DB・ClickHouse の公開ポートは開けない。
5. Volume を control・execution に追加し、`/private/claude`・
   `/private/codex`・`/private/muse`・`/workspaces` にマウントする
   （web は不要）。
6. `PORT` は Railway が注入する（Thruster・Puma が参照）。固定しない。
7. CLI 付き worker は、CI 等で `ai` ターゲットをビルドしてレジストリに
   push し、そのイメージを control・execution サービスに指定する
   （Railway の Dockerfile ビルドは既定 `app` のため）。

## 8. ngrok（明示 opt-in）

通常は不要（外部取得はポーリングのため）。Webhook デモ等でのみ使う:

```sh
NGROK_AUTHTOKEN=... docker compose --profile tunnel up ngrok
# 管理 UI: http://127.0.0.1:4040（NGROK_PORT で変更可）
```

注意:

- 公開 URL は起動ログ・管理 UI で確認し、使う相手にだけ共有する。
- Rails の Host 認可に公開ホストの許可が必要。トンネル利用時は
  `config/environments/production.rb` の `config.hosts` に公開ホストを
  追加する（既定の開発起動では不要）。
- トークンは `.env`（git 管理外）のみ。CI・イメージに混入しない。

## 9. CI

`.github/workflows/ci.yml`（テスト専用。GitHub Actions を実行基盤・
スケジューラには使わない）:

| job | 内容 |
| --- | --- |
| `unit` | `bin/test unit`（DB なし全 suite: unit/plugins/ai） |
| `integration` | 実 PostgreSQL + 実 ClickHouse サービス上で `bin/test integration`（`TEST_DATABASE_URL` + `TEST_CLICKHOUSE_*`。ClickHouse 到達の事前確認あり） |
| `zeitwerk` | `bin/rails zeitwerk:check` |
| `ops` | `docker compose config`、`ruby bin/check-compose`、`app`/`ai` ビルド、pinned CLI の `--version` 確認（claude/codex/git）+ シークレット無し `muse` 不在の確認 |
| `clickhouse-smoke` | 実 ClickHouse サービス + `./bin/setup-clickhouse` の機構確認（使い捨てスキーマ。出荷 `event_log` スキーマ自体は integration が出荷 SQL から再構築して検証） |

CI は live provider・実アカウント・資格情報を一切使わない。サブスクリ
プションのログインは検証しない（運営者作業であり、CI では不可）。
AI イメージのビルドもログインなし（`muse` はシークレット無しで不在
となり、provider 実行時失敗の契約どおり）。

## 10. 検証

### 10.1 統合受け入れで確認する範囲

- `docker compose config`、`ruby bin/check-compose` が通る。
- `docker compose up --build` 後、`./bin/smoke` が全件 ok
  （web `/up`、PostgreSQL、両 worker 起動、`DATABASE_URL` 一致、両
  supervisor の共有 DB 登録、6 件の recurring 登録、
  ClickHouse 到達時は `event_log` 存在）。
- `bin/test unit` / `bin/test integration` /
  `bin/rails zeitwerk:check` が通る（全 `smartest/**/*_test.rb` が
  いずれかの suite で実行され、沈黙 skip なし）。
- `docker build .`（既定 `app`）と `docker build --target ai .` が成功し、
  `claude --version` / `codex --version` / `git --version` が Linux 上で
  動く（`muse` はシークレット無しでは不在）。
- 管理画面が Basic 認証で 200、未認証で 401 を返す
  （`/admin`・`/admin/event_logs`・`/admin/plugins`・
  `/admin/layer_policies`）。
- Rails 経由で emit した EventLog が定期配信で実 ClickHouse に届き、
  `Observability.search` で読める。
- ClickHouse 停止状態でも web/worker が起動・応答し続ける
  （`clickhouse-init` のみ待機/失敗し、`./bin/smoke` は警告付きで継続）。
  停止中の emit は outbox に滞留し、復帰後の定期配信で届く。
- 本番同等（`RAILS_ENV=production`）の HTTP 挙動:
  `/up` は redirect なく 200（`config/environments/production.rb` の
  除外設定。Railway ヘルスチェックはこのまま動く）。
  背後は TLS 終端プロキシ前提（`assume_ssl`）のため、アプリ到達時は
  全パスが HTTPS 扱いで、`/admin` 系は HSTS 付きで配信される。

### 10.2 運営者アカウントが必要な範囲（自動検証しない）

- Railway への実デプロイ・実ドメイン公開。
- ngrok の実公開・外部 Webhook 受信。
- 各 CLI のサブスクリプションログイン・トークン更新。
  （`muse` Linux バイナリの入手を含む）
- 実 GitHub / Jira / Teams への投稿・取得。

## 11. トラブルシュート

- ポート衝突: `.env` の `WEB_PORT` / `POSTGRES_PORT` /
  `CLICKHOUSE_PORT` を空きポートに変えて `docker compose up` し直す。
- ClickHouse の初回起動は遅い（数十秒）。`clickhouse-init` はヘルス
  チェック通過を待つ。web/worker は待たずに起動し、EventLog 配信は
  ClickHouse 復帰まで outbox に滞留する。
- ClickHouse 障害時: アプリは起動継続する。復帰後に
  `docker compose up clickhouse-init` でスキーマ適用を再実行（冪等）。
- `migrate` 失敗時: `docker compose logs migrate` を見て直し、
  `docker compose up migrate` で再実行（冪等）。
- AI トークン期限切れ: 該当 volume を消さず「5.」の手順で再ログインする
  （volume を消すと再ログイン必須）。
- 他 worktree との volume 衝突: `COMPOSE_PROJECT_NAME` が checkout 毎に
  異なることを確認する。

## 12. Provider 診断は web ローカル

管理画面の provider 診断（設定済み/未設定バッジ）は、web プロセス自身
の視点で CLI バイナリと auth ホームの有無を見るだけの読み取り専用表示
である。web は `app` イメージ（CLI なし）で動き、AI auth volume も
マウントしないため、worker が `ai` イメージで正常でも web 上は未設定
に見える。これを「worker が未設定」と読んではいけない。

worker 側の真実は worker コンテナで直接確認する:

```sh
# 制御面・実行面の CLI と auth 配置（要 ai イメージ + ログイン済み volume）
docker compose exec control ls -la /usr/local/bin/claude /usr/local/bin/codex /usr/local/bin/muse
docker compose exec execution ls -la /private/claude /private/codex /private/muse
docker compose exec execution printenv AICONSHELL_MUSE_HOME
# Rails 経由の診断（web ではなく worker で実行すること）
docker compose exec execution ./bin/rails runner 'require "aiconshell/ai"; puts Aiconshell::Ai::Registry.default.catalog.inspect'
```

管理画面のバッジ自体に「web ローカル」の明記は無い（設定済み /
未設定の表示のみ）。web 上の未設定を見て worker 側を判断せず、
必ず worker コンテナで直接確認すること。
