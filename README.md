# aiconshell

AI エンジニア基盤。外部サービス（GitHub / Jira / Teams）のイベントを
取り込み、タスク化・優先度付け・AI 実行し、結果を EventLog に残す。
設計は [docs/architecture.md](docs/architecture.md)、運用手順は
[docs/deployment.md](docs/deployment.md)。

## 起動（5分）

前提: Docker（Compose v2）、Ruby 3.4.9
（`RBENV_VERSION=3.4.9 rbenv exec ...`）。

```sh
cp .env.example .env   # 初回のみ。COMPOSE_PROJECT_NAME は checkout 毎に変更
docker compose up --build
./bin/smoke            # 別ターミナルで確認（web・DB・ClickHouse・worker）
```

開く: http://127.0.0.1:3000（管理画面。`WEB_PORT` で変更可）

## テスト

```sh
bin/test unit                  # 単体（DB・外部通信なし）
bin/test integration           # 結合（実 PostgreSQL。初回は RAILS_ENV=test bin/rails db:prepare）
bin/rails zeitwerk:check       # autoload 検査
ruby bin/check-compose         # compose・queue・CI の静的検査
```

CI（`.github/workflows/ci.yml`）はテスト専用で、上記＋イメージビルド＋
実 ClickHouse スキーマ適用を行う。live provider・実アカウントは使わない。

## 操作・デプロイ

- 日常操作・AI CLI 導入・Railway・ngrok は [docs/deployment.md](docs/deployment.md)。
- 環境変数は `.env.example` が正。`execution` worker には連携資格情報を
  渡さない（compose と AI 層の両方で遮断）。

## 検証範囲

本リポジトリで自動確認できる範囲と、運営者作業の範囲を分ける:

- 自動確認: `docker compose config`、上記テスト群、`./bin/smoke`、
  `app`/`ai` イメージビルド、ClickHouse スキーマ適用。
- 運営者作業（要アカウント）: Railway 実デプロイ、ngrok 実公開、各 CLI
  のログイン（`muse` バイナリ入手含む）、実サービスへの投稿・取得。
