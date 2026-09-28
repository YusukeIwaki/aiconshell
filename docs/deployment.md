# デプロイ・運用手順

ローカル Compose と Railway で同じ分割（web / 単一 execution worker /
PostgreSQL / ClickHouse）を使うための手順書。全体設計は
[docs/architecture.md](architecture.md) を参照。

## 1. 構成

| サービス | 役割 | キュー | 環境変数 |
| --- | --- | --- | --- |
| `web` | 管理画面 | — | DB・ワークフロー設定・EventLog 既定チャネル・ClickHouse・連携資格情報 |
| `execution` | ポーリング・振分・配信・定期実行・coordination AI・AI CLI 実行（隔離 workspace）・AI連携 | `control`（既定3 threads）+ `execution`（既定1 thread）+ 別1スレッド `ai_auth_execution` | DB・ワークフロー設定・EventLog 既定チャネル・ClickHouse・連携資格情報・自アクタ・AI auth・`AICONSHELL_WORKER_ROLE=execution` |
| `migrate` | SQL マイグレーション専用（使い捨て） | — | DB・ワークフロー設定・EventLog 既定チャネル |
| `clickhouse-init` | ClickHouse スキーマ適用（使い捨て・独立） | — | ClickHouse のみ |
| `db` | PostgreSQL 17（Solid Queue 同居） | — | — |
| `clickhouse` | EventLog 検索（26.8 系） | — | — |
| `ngrok` | 任意トンネル（profile 加入時のみ） | — | トークンのみ |

境界の要点:

- Web と worker は**同一 `DATABASE_URL`**（1 DB・キュー分離）。
  キュー分離は正の `config/queue_execution.yml` + `--config-file` で行う
  （Solid Queue の CLI に `--queues` は無い）。定期実行スケジューラも
  同一ワーカーで動く（`--skip-recurring` を付けない）。実際の `queue_as`
  宣言と一致: control 系 job（poll / triage / outbound / lease 回復 /
  EventLog 配信 / maintenance）は `:control`、実行 job は `:execution`。
  旧 `config/queue_control.yml` と旧 `control` サービスは廃止済み。
- 3 pool を分ける（control 既定3 / execution 既定1 / 認証1）。
  単一の優先順位付き queue や wildcard pool へまとめない。
  長い実作業・ログインが control の実行枠を消費しないことが目的であり、
  CPU/RAM の完全隔離ではない。
- `execution` の Rails 親プロセスは Interaction / EventLog のため連携・
  ClickHouse 資格情報も持つ。AI CLI 子プロセスの明示 env からは
  `lib/aiconshell/ai/child_env.rb` が遮断する（子 env を scratch から
  構築し、DB・連携資格情報を継承しない）。`bin/check-compose` が compose
  上の親配置を検証する。
  `EVENT_LOG_TEAMS_CHANNEL`（既定チャネル名。空が既定）は資格情報では
  ないため全 Rails プロセスに渡す。`TEAMS_BOT_TARGETS_FILE` はパス指定
  のみ web・execution に渡し、実ファイルは運営者が read-only マウントする
  （「6. 資格情報ファイルのマウント」参照）。
- マイグレーションは `migrate` サービスの1プロセスのみ
  （`AICONSHELL_RUN_DB_SETUP=1`）。web/worker の起動時は実行しない。
- EventLog は結果整合性: ClickHouse 障害は起動を止めない。web/worker は
  ClickHouse に依存せず、`clickhouse-init` が独立にスキーマ適用する。
  適用までの配信は PostgreSQL の outbox に滞留し、リトライされる。
- イメージは役割別: web / migrate / clickhouse-init は `app` 固定、
  execution は `ai` 既定（`EXECUTION_TARGET` で `app` に明示切替可）。
  詳細は「5. AI CLI プロビジョニング」。
- AI の資格情報・バイナリ欠如は web 起動を止めない（未設定 provider は
  選択可・実行時失敗が契約）。
- 管理画面の provider 診断バッジは web コンテナ内のローカル表示専用
  （「12. Provider 診断は web ローカル」参照）。worker 側の真実は
  `docker compose exec execution` で確認する。
- Docker ソケットはどのコンテナにもマウントしない。

### 同時実作業数と DB pool の目安

- 既定の同時実作業数は控えめに `execution` pool 1 thread とする。
  増やす場合は `config/queue_execution.yml` の `execution` pool の
  `threads` を上げて `docker compose up --build`（Railway は再デプロイ）
  する。減らす場合も同じ箇所だけを変える。
- DB 接続の考え方は fork / async で分ける（Solid Queue 1.7）。
  `config/database.yml` の `pool` は `RAILS_MAX_THREADS` に従うが、
  その適用範囲がモードで異なる。
  - fork（compose / Railway の Linux 既定）: 各 pool は別プロセスで動き、
    `RAILS_MAX_THREADS` はプロセスごとの pool サイズになる。既定 5 は
    各プロセス（control 3 threads / execution 1 / auth 1 /
    dispatcher 系）に十分である。
  - async（macOS ローカルの `bin/jobs --mode=async`）: 全 pool・
    dispatcher・heartbeat・scheduler が同じプロセス・同じ connection
    pool を使う。同時 DB 使用の上限は control 3 + execution N +
    auth 1 + dispatcher/scheduler 分の合計になるため、既定 5 では足りない。
    async 起動例には合計に余裕を持つ `RAILS_MAX_THREADS=15` を付ける
    （README「開発ループ」の起動例どおり）。
- `execution` pool の `threads` を上げる場合は、使うモードに合わせて
  `RAILS_MAX_THREADS` も同じ worker に十分な値で揃え、PostgreSQL の
  `max_connections`（共有サーバーでは他利用環境の分も合算）を超えない
  ことを確認する。`JOB_CONCURRENCY`（worker プロセス数）は fork 時に
  プロセス数ぶん接続数を倍加させるため、通常は `1` のまま threads だけを
  調整する。

## 2. 定期実行

`config/recurring.yml` が development・production 共通のスケジュールを持つ
（test は自動実行しない）。スケジューラは単一 execution worker のみが動かし、
二重登録しない。全タスクがキュー `control` 宛てで、同一ワーカーの control
pool が消費する。

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

- worker は既定で `ai` イメージ（Claude/Codex/Muse 付き）。
  CLI 不要の検証は `EXECUTION_TARGET=app` を付けて
  起動する（「5. AI CLI プロビジョニング」参照）。
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

`Dockerfile` の `app` / `ai` ターゲットが役割別イメージを作る。
`web` / `migrate` / `clickhouse-init` は `app` 固定（CLI なし）、
`execution` は `ai` が既定（coordination AI も同一ワーカーで実行する）。
`ai` には Claude / Codex / Muse の3つが
入り、通常の `docker compose up --build` で worker に揃う。
CLI 配布物の導入とサブスクリプションの実行時認証は別物である:
ビルドにログインは不要で、認証ログインはビルドとは別の実行時手順
（本節末尾）。web には AI CLI も AI auth 環境変数・volume も渡さない
（`bin/check-compose` が検証）。

| CLI | 導入元 | 既定バージョン（ARG で上書き可） |
| --- | --- | --- |
| Node.js | 公式 tarball（x64/arm64） | `NODE_VERSION=24.21.0`（LTS） |
| `claude` | npm `@anthropic-ai/claude-code` | `CLAUDE_CODE_VERSION=2.1.283` |
| `codex` | npm `@openai/codex` | `CODEX_VERSION=0.157.1` |
| `git` | apt（AI の工程コマンド用） | ディストリビューション版 |
| `muse` | 公式公開 Linux バイナリ（lookaside 配布。自動更新ランチャーではなく固定バイナリ） | `MUSE_VERSION=1.4.0-R4302.1` + アーキテクチャ別 SHA256（ARG で上書き可。更新時はバージョンと両 SHA256 を同時に更新） |

Compose は `Dockerfile` の target から直接ビルドする。単体の
`docker build -t ...` で付けたタグが Compose から自動で使われることは
ない。起動・再ビルドは必ず Compose コマンドで行う:

```sh
# 通常起動（worker は ai）
docker compose up --build
# CLI 不要のローカル検証（worker も app に明示切替）
EXECUTION_TARGET=app docker compose up --build
```

既存の `.env` に `CONTROL_TARGET=app` / `EXECUTION_TARGET=app` がある場合は、
`CONTROL_TARGET` の行を削除し、`EXECUTION_TARGET` の値を `ai` に変更する
（旧 control サービスは廃止済み）。

下記は単体ビルド（private registry 用など）の例であり、付けたタグは
Compose から自動では使われない。どちらもログイン情報なしでビルドできる:

```sh
# 基本イメージ
docker build -t aiconshell:app .
# CLI 付き（Claude / Codex / Muse の3つ入り）
docker build --target ai -t aiconshell:ai .
```

`muse` の取り扱いを正確に述べる: ビルドは公式の公開 manifest
（https://api.meta.ai/muse-code/channels/muse-stable）と同じ配布元から
ネイティブ Linux バイナリを取得し、アーキテクチャ別 SHA256 を検証して
`/usr/local/bin/muse` に置く。取得元は公開 URL であり、ビルド時の
ログイン・API キー・auth cache は不要である。自動更新するランチャー
ではなく固定バージョンのバイナリを同梱し、`muse --version` で確認する。
認証資格情報は常にイメージ外（マウント volume）に置く。資格情報や
バイナリをリポジトリに混入させないこと。配布物の導入と実行時の認証は
別物である: 未認証の provider は選択可・実行時失敗が契約であり、
ログインは下記の実行時手順で行う。

CLI 不要のローカル検証向けに、worker を `app` に明示切替できる
（`.env` の既定は `ai`）:

```sh
EXECUTION_TARGET=app
```

認証ホーム（AI 層 `Config` と同一契約）:

| provider | コンテナ内 env | execution volume |
| --- | --- | --- |
| claude | `CLAUDE_CONFIG_DIR=/private/claude` | `execution_claude_auth` |
| codex | `CODEX_HOME=/private/codex` | `execution_codex_auth` |
| muse | `AICONSHELL_MUSE_HOME=/private/muse`（XDG home） | `execution_muse_auth` |

muse は XDG 基準: `AICONSHELL_MUSE_HOME` は `muse` ディレクトリを**含む**
ディレクトリを指し、認証は `/private/muse/muse/auth.json` に置かれる。
`MUSE_CONFIG_DIR` という変数は存在しない（native CLI は解釈しない）。
実行子プロセスには `XDG_CONFIG_HOME` + `MUSE_AUTH_PATH` だけが渡る
（`ChildEnv` の契約）。

volume は uid 1000（`rails`）で書けるよう image 側で用意済み。通常の
CLI トークン更新が volume に永続化される。通常は管理画面の「AI連携」から
公式ログインを開始し、運営者がブラウザで承認する。詳細は
[AIアカウント連携](ai-connections.md)。単一ワーカー化の前後で execution 側
volume は継続使用する。旧 control 側の host volume は消さず、認証 cache を
コピーしない。再ログインと旧 control 認証の失効は #20 の運用入口を使う。
コンテナから手動で始める場合は execution を使う:

```sh
docker compose run --rm -it execution bash
# claude / codex は compose の env がそのまま効く
claude auth login --claudeai
codex login --device-auth -c 'forced_login_method="chatgpt"' -c 'cli_auth_credentials_store="file"'
# muse だけは対話シェルで XDG を明示する（アプリ経由の実行では不要）
export XDG_CONFIG_HOME=$AICONSHELL_MUSE_HOME
muse login     # または公式フロー
```

実行 workspace（`AICONSHELL_EXECUTION_ROOT=/workspaces`）は execution に
`ai_workspaces` volume としてマウントされる。アプリ
ソース外の永続領域で、uid 1000 所有。triage の `policy-coordination`
と実行 run の作業ディレクトリがここに作られる。

## 6. 資格情報ファイルのマウント

`GITHUB_PRIVATE_KEY_FILE`・`JIRA_API_TOKEN_FILE`・
`TEAMS_CLIENT_SECRET_FILE`・`TEAMS_BOT_APP_PASSWORD_FILE`・
`OAUTH_ATLASSIAN_CLIENT_SECRET_FILE`・`OAUTH_MICROSOFT_CLIENT_SECRET_FILE`・
`TEAMS_BOT_TARGETS_FILE` はコンテナ内パスだけを環境変数で渡す。
実ファイルの内容は compose・Railway・イメージ・Git のいずれにも
入れない。プラグインは値（`GITHUB_PRIVATE_KEY` 等）とファイルの
どちらか片方があれば動き、両方空なら「未設定」として実行時失敗する。
委任 OAuth（`OAUTH_*`）も同じ扱いであり、値とファイルの混在・転用はしない。
個人 PAT の運用・PAT 入力 UI・PAT 専用 plugin は提供しない。

Compose ではホストの private ファイルを対象サービスへ read-only で
bind マウントする（`migrate`・`clickhouse-init` には付けない）。
`compose.override.yml`（git 管理外）の例:

```yaml
services:
  web:
    volumes:
      - type: bind
        source: /srv/secrets/aiconshell/teams-bot-targets.json
        target: /run/secrets/teams-bot-targets.json
        read_only: true
  execution:
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

- コンテナの UID 1000 が読める所有者・権限にする。たとえば所有者 UID 1000 の
  `0600`、またはグループ GID 1000 の `0640` を使い、親ディレクトリの探索権限も確認する。
  ホストの運営者だけが読める `0600` のままでは、コンテナから読めない場合がある。
  `docker compose exec execution test -r /run/secrets/teams-bot-targets.json` で確認する。
  AI 実行 workspace（`/workspaces`）やリポジトリ内には置かない。
- `TEAMS_BOT_TARGETS_FILE` の JSON 形式は
  `plugins/teams/README.md`「Bot 参照の対応表」が正。
  Graph の team / channel ID と Bot conversation 参照の対応表であり、
  受信済みの実際の参照だけを載せる。自動生成はしない。
- Railway にはホスト bind が無い。execution の既存 `/data` volume に
  `/data/integrations/teams-bot-targets.json` を UID 1000 が読める権限で配置し、
  `TEAMS_BOT_TARGETS_FILE` にそのパスを指定する。他サービスとは共有されない。
  通常の資格情報は値型の環境変数でも設定できる。Teams の対応表が未配置なら
  Bot による送信は実行時に失敗する。

## 7. Railway

実デプロイ・有料リソース作成・ログインは運営者作業。同一 project / environment に
同じ repository を使う web・execution と、PostgreSQL・ClickHouse を配置する。
DB / ClickHouse は private networking で接続し、公開ポートを作らない。
1 台の PostgreSQL サーバーで独立した利用環境を複数運用する場合は
[docs/railway-environments.md](railway-environments.md) も参照。

### サービスごとの設定とビルド

**2026-09-27 確認:** Railway は Config-as-Code を非推奨としており、新規サービスは
TOML / JSON に opt-in できない。既存利用サービスの対応期限は 2026-12-01。
新規サービスは下表を dashboard の Build / Deploy 設定に指定する。
このリポジトリの TOML は既存サービス用の互換設定であり、新規サービスを自動構築しない。
継続的な構成管理には Railway の Infrastructure as Code への移行が必要。
[公式 Config-as-Code と移行案内](https://docs.railway.com/config-as-code)

| サービス | 既存サービスの Config File Path | Start Command | Pre-deploy Command | Healthcheck Path |
| --- | --- | --- | --- | --- |
| web | `/railway.toml` | `./bin/thrust ./bin/rails server` | `./bin/rails db:prepare` | `/up`（timeout 300 秒） |
| execution | `/railway.execution.toml` | `./bin/jobs --config-file=config/queue_execution.yml` | なし | なし |

旧 `control` サービス（`/railway.control.toml`、廃止）は下の「旧 control 停止から
単一 execution への切替」に従って廃止する。新規サービスは作らず、既存 execution
を更新する。

全サービスは repository ルートの `Dockerfile` でビルドする。Railway はこのファイルを
自動検出するため、API の builder enum に `DOCKERFILE` を指定しない（`RAILPACK` のままでよい）。
Dockerfile Path は `Dockerfile`、Root Directory は repository のルート。
通常の Restart Policy は On Failure、最大 retry は 10。
既存 Config-as-Code サービスは Settings で **サービスごとに上表の絶対 repository path を選択**する。
設定ファイル内の値は dashboard より優先されるため、web の TOML のまま worker の
Start Command を dashboard で上書きしても切り替わらない。
worker の dashboard に残っている Healthcheck Path と Pre-deploy Command も削除し、
deployment details で実際の起動コマンド・設定元を確認する。
[設定の優先順位](https://docs.railway.com/config-as-code/reference)

Service Variables の `RUNTIME_TARGET` は web に `app`、execution に `ai` を設定する。
Dockerfile の最後の `runtime` stage がこの build argument で既存の `app` / `ai` stage を選ぶ。
Railway は Dockerfile に宣言した `ARG` に service variable を渡す。
Compose は web `app` 固定・worker `ai` 既定（`CONTROL_TARGET` /
`EXECUTION_TARGET` で `app` に明示切替可）で同じ分離を行う。
[Railway の Docker build variables](https://docs.railway.com/builds/dockerfiles#using-variables-at-build-time)

repo build の `ai` には Claude / Codex / Muse CLI が入る（公開配布からの
取得であり、ビルド時ログイン不要）。Railway service variable から
binary や認証を image に埋め込まない。private registry の image を
source にする運用も可能で、その場合も上表の worker 設定・以下の専用
volume / 個別ログインを使う。未認証の provider は未構成のままであり、
選択時に実行エラーになる。

### 環境変数と独立した volume

| 変数 | 設定先と値の例 |
| --- | --- |
| `DATABASE_URL` | web / execution にその利用環境の専用 role 接続文字列。管理者接続（`${{Postgres.DATABASE_URL}}`）をそのまま使わない。複数環境は [docs/railway-environments.md](railway-environments.md) |
| `CLICKHOUSE_URL` | web / execution に `http://${{ClickHouse.RAILWAY_PRIVATE_DOMAIN}}:8123` |
| `CLICKHOUSE_DATABASE/USER/PASSWORD` | web / execution に利用環境専用の制限付き ClickHouse database / user 資格情報。operator 資格情報は ClickHouse 側だけに置き、アプリには渡さない |
| `SECRET_KEY_BASE` | web / execution に `bin/rails secret` で生成した秘密値（利用環境ごとに別の値） |
| `ADMIN_USERNAME/ADMIN_PASSWORD` | web の管理画面用（未設定は fail closed） |
| `ADMIN_API_TOKEN` | web の JSON 管理 API（`/api/admin/task_requests`）用 Bearer 値（未設定は fail closed。UI 認証とは別。`docs/task-requests.md`） |
| `RAILS_ENV` | web / execution に `production` |
| `EVENT_LOG_TEAMS_CHANNEL` | web / execution に同じ `channel:<team>/<channel>`。空なら通知しない |
| `TEAMS_BOT_TARGETS_FILE` | execution の `/data/integrations/teams-bot-targets.json`（資格情報ファイル節参照） |
| `DISCORD_BOT_TOKEN` | web / execution に Discord Bot のトークン。poll（`discord:channel/<channelId>`）・返信・通知に使う。値型の環境変数で渡し、Git に入れない（Bot 作成・招待・権限は `plugins/discord/README.md`） |
| `AICONSHELL_EXECUTION_ROOT` | execution は `/data/workspaces`。web は `/workspaces`（image 内にある boot 設定用パス） |
| ワークフロー設定 | `AICONSHELL_ALLOWED_SCOPES`・lease/timeout/attempts・`AICONSHELL_DEMO_MODE` は web / execution に同じ値 |
| 連携資格情報 | execution / web（`GITHUB_*`・`JIRA_*`・`TEAMS_*`・委任 OAuth `OAUTH_*`）。AI CLI 子プロセスには継承させない（`ChildEnv` の契約）。`migrate` には付けない |
| 委任 OAuth | execution / web に `OAUTH_ATLASSIAN_*`・`OAUTH_MICROSOFT_*`（`bin/check-compose` が検証）。運用名義は Bot 運用と OAuth2 代理運用の2種類のみで PAT 運用はなし |
| 自アクタ ID | execution に `AICONSHELL_SELF_ACTOR_IDS`・`JIRA_SERVICE_ACCOUNT_ID`（委任 OAuth の自己投稿抑制は receipt 照合であり actor ではない） |
| `CLAUDE_CONFIG_DIR` | execution に `/data/auth/claude` |
| `CODEX_HOME` | execution に `/data/auth/codex` |
| `AICONSHELL_MUSE_HOME` | execution に `/data/auth/muse` |
| `AICONSHELL_AI_HOME` | execution に `/tmp/aiconshell-ai-home`（子プロセスの一時 HOME） |
| `AICONSHELL_CLAUDE_BIN` / `AICONSHELL_CODEX_BIN` / `AICONSHELL_MUSE_BIN` | execution に `/usr/local/bin/claude` / `/usr/local/bin/codex` / `/usr/local/bin/muse` |
| `AICONSHELL_WORKER_ROLE` | execution に `execution`。web には設定しない |

execution に**1 個だけ volume を作り、`/data` に mount**する。
volume 内に `auth/claude`・`auth/codex`・`auth/muse`・`workspaces` を置く。
既存 execution の volume と認証はそのまま継続使用する。旧 control の
volume は消さず、認証 cache をコピーしない（再ログインと旧 control 認証の
失効は #20 の運用入口を使う）。
web には AI 用 volume を付けない。

Railway の volume は 1 サービス 1 個で、volume を持つサービスは複数 replica にできない。
execution は 1 instance にし、volume を使う再デプロイには停止時間がある。
image 内の `chown` は、後から mount される Railway volume の所有権を変更しない。
[公式 volume 制約・権限](https://docs.railway.com/volumes/reference#caveats)

### 初回だけ volume の所有者を設定する

新しい空の execution volume に対して初期化する。
まだ通常の Rails worker と AI ログインを起動しない。

1. execution サービスに `/data` volume を mount し、`RAILWAY_RUN_UID=0` を一時設定する。
   `AICONSHELL_RUN_DB_SETUP` は未設定または `0` にする。Start Command は `/bin/sleep infinity`、
   Pre-deploy Command / Healthcheck Path は空、Restart Policy は Never にする。
   既存 Config-as-Code サービスでは `/railway.volume-init.toml` を選択して同じ設定を使う。
   この変更を deploy し、Rails / jobs を起動しない待機コンテナにする。
2. 運営者のローカル端末から対象の remote shell に接続する（project / environment を事前に link）。

   ```sh
   railway ssh --service execution
   ```

   **接続先コンテナ内**で次を実行する。`id -u` が 0 でなければ続行しない。

   ```sh
   test "$(id -u)" = 0 || exit 1
   test -d /data || exit 1
   install -d -o 1000 -g 1000 -m 0700 \
     /data/auth /data/auth/claude /data/auth/codex /data/auth/muse /data/workspaces
   chown 1000:1000 /data
   chmod 0700 /data
   stat -c '%u:%g %a %n' /data /data/auth /data/auth/claude /data/auth/codex /data/auth/muse /data/workspaces
   exit
   ```

3. `RAILWAY_RUN_UID` を削除して image の `USER 1000:1000` に戻し、まず待機コマンドで再 deploy する。
   Railway の SSH shell は root で始まることがあるため、SSH の `id -u` とアプリの実行 UID を混同しない。
   `/proc/1/status` の `Uid` が `1000` であることと、
   `railway ssh --service execution -- runuser -u rails -- test -w /data/workspaces` の成功を確認する。
4. `railway ssh --service execution -- runuser -u rails -- bash` で UID 1000 の shell を開き、
   `id -u` を確認して、その worker が使う provider に個別ログインする。
   root のまま認証ファイルを作らない。
   「5. AI CLI プロビジョニング」の公式 subscription login 手順を使い、Muse の対話シェルでは
   `export XDG_CONFIG_HOME="$AICONSHELL_MUSE_HOME"` を先に実行する。
   通常の token refresh は execution の volume だけに保存される。
5. web の SQL migration 成功後、execution の通常 Start Command / On Failure policy に戻す。
   既存 Config-as-Code サービスでは `/railway.execution.toml` を
   再選択して deploy する。`RAILWAY_RUN_UID=0` と volume-init 設定を通常運用に残さない。

volume は build / pre-deploy での権限初期化には使わず、mount 済みの待機コンテナで設定する。
root を要するのはこの初回の filesystem 設定だけで、通常の Rails / CLI は非 root で動かす。

### SQL と ClickHouse の初期化

web の Pre-deploy Command は `./bin/rails db:prepare` のみ。必要な workflow env は
pre-deploy にも渡す。worker は SQL migration 成功後に起動する。
ClickHouse スキーマは logging availability とアプリ起動を分離し、private network 内の
operator コンテキストで初期化する。先に利用環境専用 database を作り、その database を
指定して `db/clickhouse/*.sql` を適用する。アプリのソースがある一時的な初期化コンテナなら
`bin/setup-clickhouse` を使える。通常のアプリ runtime は `SELECT` / `INSERT` のみを持つため、
その runtime 資格情報で DDL を実行しない。operator 資格情報を常設のアプリへ追加しない。
詳しい権限分離は [複数利用環境の初期化手順](railway-environments.md#追加手順) を参照。

`railway run` は service variables を取得して**ローカルで**実行する CLI なので、
private DNS の ClickHouse 初期化には使わない。SSH 接続には Railway に登録済みの SSH key が必要。
初期化成功まで EventLog delivery は PostgreSQL に残って再試行する。
`PORT` は Railway の注入値を使い、web の公開ドメインだけを有効化する。
[railway ssh](https://docs.railway.com/cli/ssh)・[railway run](https://docs.railway.com/cli/run)

SSH を使わず初期化する場合は、運営者が管理する一時 Start Command / 初期化コンテナを
使える。volume の初期化は対象 worker の mount 済みコンテナ内で行い、完了後は
`RAILWAY_RUN_UID` を外して UID 1000 で書き込みを確認し、通常 Start Command に戻す。
DB 初期化用コンテナと一時的な operator 資格情報は作業後に削除する。
ログには完了マーカーだけを出し、秘密値・環境変数一覧・認証キャッシュを出さない。

ローカルの静的検証と、Railway 上のデプロイ・private DNS 到達・subscription login の
確認結果は分けて記録する。CLI 同梱や worker 起動だけでアカウント認証済みとは扱わない。

### 旧 control 停止から単一 execution への切替

本番インフラ変更は検収者が行う。実装者は検証に使う自分の Compose
project/volume だけを操作する。切替は次の順序で行う:

1. 旧 control の GitHub 自動デプロイを解除してから、旧 control worker を
   停止する（新旧の scheduler が二重に recurring を登録しないように先に
   止める。自動デプロイを残すと main push 後に廃止済み config で再起動する）。
   停止前に control queue の滞留と `ai_auth_control` の進行中セッションを
   確認し、進行中の認証は終わるかキャンセルしてから止める。
2. 既存 execution の設定と連携 env を準備する。本番調査では各 Railway
   サービスが dashboard の explicit startCommand を使い、config-as-code
   file は未指定だったため、repository の TOML 変更だけでは反映されない
   （§7 冒頭の表と優先順位どおり）。dashboard の実際の設定を確認し、
   execution の dashboard startCommand を
   `./bin/jobs --config-file=config/queue_execution.yml`（残っている
   `--skip-recurring` を除去）にしたうえで、`DATABASE_URL`・
   ワークフロー設定・`EVENT_LOG_TEAMS_CHANNEL`・ClickHouse・連携資格情報・
   自アクタ ID・AI auth・`AICONSHELL_WORKER_ROLE=execution`・
   `RUNTIME_TARGET=ai` を揃える。`/data` volume
   （`/data/auth/*`・`/data/workspaces`）は既存のまま継続使用する。
   旧 control の volume は消さず、認証 cache をコピーしない。
3. execution をデプロイする。単一ワーカーが control / execution /
   `ai_auth_execution` の 3 pool と scheduler を起動することを
   deployment details で確認する。
4. 検証する: web ヘルスチェックと管理画面認証、共有 DB 上の Supervisor
   heartbeat（1 件）と recurring 6 件の登録、ClickHouse schema / search の
   read-only 確認、control queue の消費再開。旧 control 認証の失効は #20 の
   運用入口（[AIアカウント連携](ai-connections.md)）を使う。
5. 検証後に不要な旧 control サービスを廃止する（サービス削除と
   `/railway.control.toml` 参照の除去）。旧 control の volume は検証完了まで
   残し、不要確定後に運営者が削除する。

rollback: 切替検証で異常があれば、まず単一 execution worker を停止する
（scheduler の二重起動を避ける）。そのうえで両 worker（必要なら web も）を
変更前のリリース/イメージ・起動設定へ戻して再デプロイする。旧 start
command（`--skip-recurring` 付き）に戻すだけでは成立しない。新コードには
`config/queue_control.yml` がなく、execution は引き続き control queue を
消費するため、execution を戻さず旧 control を再起動するだけでは二重消費・
scheduler 二重起動になる。旧 control の volume と認証は残してあるため、
再ログインは不要である。新 execution デプロイで DB migration は走らない
（pre-deploy は web のみ）ため、schema の巻き戻しは発生しない。

## 8. ngrok（明示 opt-in）

通常は不要（外部取得はポーリングのため）。一時的な公開デモに使う場合は
既定の `RAILS_ENV=development` で次の手順を行う。公開前に `.env` の
`ADMIN_USERNAME` / `ADMIN_PASSWORD` と十分に長い `SECRET_KEY_BASE` を設定する。

```sh
# .env に NGROK_AUTHTOKEN を設定してから起動
docker compose --profile tunnel up -d ngrok
# 管理 UI: http://127.0.0.1:4040（NGROK_PORT で変更可）
```

起動ログ・管理 UI で公開 URL を確認し、**そのホスト名だけ**を `.env` に
追加する。たとえば URL が `https://your-assigned-name.ngrok-free.app` の場合:

```dotenv
RAILS_DEVELOPMENT_HOSTS=your-assigned-name.ngrok-free.app
```

```sh
# Rails は起動時に読むため、restart ではなく環境を反映する recreate を使う
docker compose up -d --no-deps --force-recreate web
```

ホスト許可前は Rails が公開 URL のリクエストを `403 Blocked hosts` で
拒否する。Rails 8 組み込みの `RAILS_DEVELOPMENT_HOSTS` はカンマ区切りの
ホスト名を既定の development 許可リストに追加する。Compose は web に
だけ渡し、`https://`・パス・先頭の `.`・ワイルドカードは指定しない。
複数ホストが必要なら各ホストを列挙する。この変数は production の設定には
使われない。

Host 認可と CSRF 検証は有効なままにし、ngrok の `--host-header` 等で
公開ホストを内部名へ書き換えない。ブラウザから届く公開ホストと HTTPS の
情報を維持する。公開 URL は使う相手にだけ共有し、ホスト名が変わったら
許可リストを更新して web を再作成する。

利用終了後は `docker compose --profile tunnel stop ngrok` で停止し、
`.env` の `RAILS_DEVELOPMENT_HOSTS` を空に戻して上記の web 再作成を行う。
トークンは `.env`（git 管理外）のみへ保存し、CI・イメージに混入しない。

実トンネルなしでも、許可したホストを指定してローカルの Host 認可を
確認できる（`WEB_PORT` を変更した場合は URL も変更）:

```sh
curl -i -H 'Host: your-assigned-name.ngrok-free.app' http://127.0.0.1:3000/up
# 許可済みなら 200。別ホストでは 403 を維持する。
curl -i -H 'Host: unlisted.example.invalid' http://127.0.0.1:3000/up
```

## 9. CI

`.github/workflows/ci.yml`（テスト専用。GitHub Actions を実行基盤・
スケジューラには使わない）:

| job | 内容 |
| --- | --- |
| `unit` | `bin/test unit`（DB なし全 suite: unit/plugins/ai） |
| `integration` | 実 PostgreSQL + 実 ClickHouse サービス上で `bin/test integration`（`TEST_DATABASE_URL` + `TEST_CLICKHOUSE_*`。ClickHouse 到達の事前確認あり） |
| `zeitwerk` | `bin/rails zeitwerk:check` |
| `ops` | `docker compose config`、worker target 解決（既定 ai・offline app。旧 control サービス不在も確認）、`ruby bin/check-compose`、`app`/`ai` ビルド、`app` の CLI 不在確認（claude/codex/muse）、pinned CLI の `--version` 確認（claude/codex/muse/git） |
| `clickhouse-smoke` | 実 ClickHouse サービス + `./bin/setup-clickhouse` の機構確認（使い捨てスキーマ。出荷 `event_log` スキーマ自体は integration が出荷 SQL から再構築して検証） |

CI は live provider・実アカウント・資格情報を一切使わない。サブスクリ
プションのログインは検証しない（運営者作業であり、CI では不可）。
AI イメージのビルドもログインなし（3 CLI は公開配布から取得。未認証
provider は選択可・実行時失敗の契約どおり）。

## 10. 検証

### 10.1 統合受け入れで確認する範囲

- `docker compose config`、`ruby bin/check-compose` が通る。
  通常設定は web=app・execution=ai と解決され、
  app 明示切替も有効。旧 control サービスは存在しない。
- `docker compose up --build` 後、`./bin/smoke` が全件 ok
  （web `/up`、PostgreSQL、単一 worker 起動、`DATABASE_URL` 一致、単一
  supervisor の共有 DB 登録、6 件の recurring 登録、
  ClickHouse 到達時は `event_log` 存在）。3 pool の分離は
  `bin/check-compose` が静的に検証し、execution 枠の占有中も control 処理
  が進むことは外部 provider なしの pool 分離確認で確かめる（下の pool 分離確認参照）。
- `bin/test unit` / `bin/test integration` /
  `bin/rails zeitwerk:check` が通る（全 `smartest/**/*_test.rb` が
  いずれかの suite で実行され、沈黙 skip なし）。
- `docker build .`（既定 `app`）と `docker build --target ai .` が成功し、
  `app` には `claude` / `codex` / `muse` が無く（`command -v` 不在）、
  `ai` では `claude --version` / `codex --version` /
  `muse --version` / `git --version` が Linux 上で動く。
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

### pool 分離確認（外部 provider なし）

execution 枠の占有中も control 処理が進むことは、実 provider・実アカウント
なしで次の順序で確認する:

1. `ruby bin/check-compose` で 3 pool の分離（control 3 / execution 1 /
   認証1、wildcard なし）を静的に検証する。
2. 起動中スタックの `solid_queue_processes` で Worker 3 行の live 配置を
   確認する（`queues` が control / execution / `ai_auth_execution`、
   `pool_size` が 3 / 1 / 1。「12.」の SQL 参照）。
3. `execution` queue に長時間 job を積んで単一 execution thread を占有させ、
   その間に `control` queue の job が完了することと、2 件目の `execution`
   job が待機することを確認する。リポジトリに job クラスを追加せず行う
   場合は、一時 PG 上の
   `AICONSHELL_WORKER_ROLE=execution RAILS_MAX_THREADS=15 bin/jobs --mode=async`
   検証プロセスと /tmp の probe 定義を使う（本番・共有 DB では行わない）。

### 10.2 運営者アカウントが必要な範囲（自動検証しない）

- Railway への実デプロイ・実ドメイン公開。
- ngrok の実公開・外部 Webhook 受信。
- 各 CLI のサブスクリプションログイン・トークン更新。
- 実 GitHub / Jira / Teams / Discord への投稿・取得。

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
# CLI と auth 配置（要 ai イメージ + ログイン済み volume）
docker compose exec execution ls -la /usr/local/bin/claude /usr/local/bin/codex /usr/local/bin/muse
docker compose exec execution ls -la /private/claude /private/codex /private/muse
docker compose exec execution printenv AICONSHELL_MUSE_HOME
# Rails 経由の診断（web ではなく worker で実行すること）
docker compose exec execution ./bin/rails runner 'require "aiconshell/ai"; puts Aiconshell::Ai::Registry.default.catalog.inspect'
# 3 pool の live 配置（control 3 / execution 1 / ai_auth_execution 1）
docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "SELECT kind, ((metadata::json)->>'queues'), ((metadata::json)->>'pool_size') FROM solid_queue_processes WHERE kind = 'Worker'"
```

管理画面のバッジ自体に「web ローカル」の明記は無い（設定済み /
未設定の表示のみ）。web 上の未設定を見て worker 側を判断せず、
必ず worker コンテナで直接確認すること。
