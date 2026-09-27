# Railway 複数利用環境の運用（共有 PostgreSQL サーバー）

1 台の PostgreSQL サーバーを共有し、論理 DB とログインロールを分けて
独立した aiconshell 利用環境を複数運用する手順書。単一環境の起動・
volume 初期化の詳細は [docs/deployment.md](deployment.md) が正であり、
本書はその差分だけを述べる。

## 概念

- 利用環境（installation）= 専用 DB + Web / control / execution の3サービス
  （Solid Queue はその DB に同居）+ 専用の Rails・管理・連携 secrets +
  worker 専用 `/data` volume 2 個 + ClickHouse の専用 database / user。
- 同一利用環境の Web replica 追加は同じ DB・`SECRET_KEY_BASE`・認証設定を使う。
  DB を分けて Web / control / execution 一式を揃える独立環境とは別物である。
  Web だけ別 DB に向けて既存 worker を共有しない。
- Railway environment 間は private network が分離される。本パターンの
  独立サービス群は**同一 project / 同一 environment** に置く。
  別 environment へ複製しても private 接続は共有されない。
- PostgreSQL と ClickHouse は private networking で接続し、公開ドメインは
  各利用環境の Web のみに付ける。
- PostgreSQL の管理者接続文字列はアプリに注入しない。各利用環境は
  superuser / createdb / createrole を持たない専用 login role で接続する。

## 変数

`DATABASE_URL` 行の詳細は [docs/deployment.md](deployment.md) §7 の表も参照。
shared variable を使う場合は利用環境の接頭辞を付け、必要なサービスからのみ参照する。
例（初期環境の DB / role 名は `aiconshell_production`）:

| shared variable（例） | 参照するサービス |
| --- | --- |
| `AICONSHELL_PRODUCTION_DATABASE_URL` | その利用環境の web / control / execution の `DATABASE_URL` |
| `AICONSHELL_PRODUCTION_SECRET_KEY_BASE` | 同上の `SECRET_KEY_BASE` |

- `DATABASE_URL` には専用 role の接続文字列だけを入れる。
  管理者接続（例: `${{Postgres.DATABASE_URL}}`）をそのまま参照しない。
- 他環境の連携資格情報を渡さない。`execution` には連携資格情報を渡さない
  （既存境界どおり）。
- `railway variable list ... --json` は秘密値をそのまま表示する。
  出力を Issue・ログ・リポジトリに貼らない。

## 追加手順

DB 名・role 名・パスワードは運営者が決める。無関係な DB / user を
変更・削除しないこと。

1. PostgreSQL サーバーに接続し、専用 role と DB を作る（識別子は例示）。
   role に superuser / createdb / createrole を付けない。

   ```sql
   CREATE ROLE "example_app" LOGIN PASSWORD '...';
   CREATE DATABASE "example_db" OWNER "example_app";
   REVOKE CONNECT ON DATABASE "example_db" FROM PUBLIC;
   GRANT CONNECT ON DATABASE "example_db" TO "example_app";
   ```

2. ClickHouse に利用環境専用の database と制限付き user を用意する
   （schema provisioning と runtime 読み書き資格情報の分離）。
   運営者が operator 権限で database を作り、その database を選択して
   `db/clickhouse/*.sql` を適用する。DDL には既存 `bin/setup-clickhouse` を
   operator コンテキストで実行できる。アプリに恒久的な管理権限は付けない。
   次に、その database だけに `SELECT` / `INSERT` を許可した別の user を作り
   （operator / access-management 権限なし）、その制限付き資格情報だけを
   当該利用環境の web / control の `CLICKHOUSE_DATABASE/USER/PASSWORD` に入れる。
   operator 資格情報は平常時 ClickHouse 側だけに置く。初期化用コンテナへ一時的に
   渡した場合は、完了後にそのコンテナと一時設定を削除する。
   `execution` には ClickHouse 資格情報を渡さない。
3. その利用環境の web / control / execution サービス群を用意する。
   新規サービスは Railway CLI / API / dashboard で設定する
   （TOML への自動 opt-in は無い。既存 TOML 互換設定の注意は
   [docs/deployment.md](deployment.md) §7 どおり）。
4. 変数を設定する（前節の表）。管理者接続・他環境の秘密を混ぜない。
5. マイグレーションは web の predeploy（`./bin/rails db:prepare`）で1回だけ。
   worker 起動時には実行しない。
6. control / execution の `/data` volume を既存 runbook
   （[docs/deployment.md](deployment.md) §7「初回だけ volume の所有者を設定する」）
   どおりに初期化し、一時設定を外して UID 1000 に戻す。
7. worker を通常 Start Command（control / execution の queue config）に戻して起動する。
8. 確認: 接続先 DB 名・current user、両 worker の共有 DB 登録、
   Web ヘルスチェックと管理画面認証、ClickHouse schema / search を
   read-only に確認する。実 AI や外部投稿は確認に使わない。

## 確認に使う CLI

```sh
railway status --project "$PROJECT_ID" --environment "$ENVIRONMENT_ID" --json
railway ssh --project "$PROJECT_ID" --environment "$ENVIRONMENT_ID" --service web -- ./bin/rails runner 'puts [ActiveRecord::Base.connection_db_config.database, ActiveRecord::Base.connection.select_value("SELECT current_user")].inspect'
```

- `railway ssh` の本体は remote container 内で動く。`railway run` はローカル実行なので
  private DNS 宛てに使わない（[docs/deployment.md](deployment.md) §7 どおり）。
- worker 登録の目安は `./bin/smoke` と同じ考え方:
  共有 DB 上の Supervisor heartbeat と control の recurring 登録を read-only に見る。
- 実デプロイの受け入れ結果は本書に書かない。調整担当が別途記録する。

## バックアップと復元

- 利用環境ごとの dump（論理 DB 単位）と、サーバー全体の volume backup は別物。
  前者はその環境だけ戻せる。後者は全環境まとめての時点に戻る。
- 同じサーバー共有はリソース共有であり、障害分離ではない。
  サーバー停止・volume 喪失は全利用環境に影響する。

## 備考

- AI / 外部連携の認証は利用環境ごとに独立。未設定の provider は
  選択可・実行時失敗の契約どおりであり、資格情報を転用・コミットしない。
