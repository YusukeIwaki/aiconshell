# 検証記録

2026-09-27 にローカルで実施。実装セッションの報告に加え、統合担当が最終プラグインと
スナップショット改訂処理を組み合わせた checkout で再実行した。

## Smartest

| 対象 | 結果 | 境界 |
| --- | --- | --- |
| `smartest/unit` | 62 / 62 | 共通契約・層の境界・EventLog の純粋ロジック |
| `smartest/plugins` | 96 / 96 | schema、認証要求、改ページ、cursor、HTTP エラー。注入 transport と localhost HTTP サーバー |
| `smartest/ai` | 79 / 79 | argv、環境変数、schema、timeout、プロセス群・出力上限。fake CLI / runner |
| `smartest/integration` | 153 / 153 | 実 PostgreSQL と実 ClickHouse、管理画面・workflow・配信・受け入れ経路 |
| `bin/rails zeitwerk:check` | 成功 | Rails の定数ロード |

合計 390 件、失敗 0 件。ClickHouse 系を含め、統合テストの skip はない。
Ruby 3.4.9、Rails 8.0.5.1、PostgreSQL 17.2、ClickHouse 26.8.11.7 を使用した。
新規の `*_test` データベースで `RAILS_ENV=test bin/rails db:prepare` を実行し、
Solid Queue と domain / EventLog テーブル、改訂管理の追加 migration を確認した。

再実行は `bin/test unit` と `bin/test integration` を使う。前者は fixture の名前空間を
分離するため、unit / plugins / ai を別プロセスで実行する。複数 suite を一度の
`smartest` コマンドへ連結する実行方法はサポートしない。

統合テストに指定する環境変数:

- `RAILS_ENV=test`、`TEST_DATABASE_URL`（末尾が `_test` の PostgreSQL DB）。
- `TEST_PG_HOST` / `TEST_PG_PORT` / `TEST_PG_DBNAME` / `TEST_PG_USER` /
  `TEST_PG_PASSWORD` も同じ DB に合わせる（EventLog の PostgreSQL ポート試験）。
- `TEST_CLICKHOUSE_URL` / `TEST_CLICKHOUSE_DATABASE` / `TEST_CLICKHOUSE_USER` /
  `TEST_CLICKHOUSE_PASSWORD` は専用テスト DB に向ける。

テスト対象 DB のテーブルを作成・削除する試験があるため、開発・本番 DB は指定しない。

## 受け入れ経路

`smartest/integration/acceptance/end_to_end_test.rb` は次のアプリケーションコードを
実際につなぐ。外部サービスの HTTP transport と、一時ディレクトリに作る `claude`
実行ファイルだけを置き換える。subscription login や外部投稿は行わない。

1. 実 GitHub adapter / Registry が installation token 交換、課題、独立した
   repository comment streams、workflow runs を読み、schema を検証する。
2. Interaction がイベントと cursor を実 DB に保存する。
3. Coordination が課題を inbox にし、追加コメントを人間のフィードバックとして保持する。
   コメント追加による親課題の日時更新だけでは新しい課題改訂を作らない。
4. 実 Ai::Runner / ProcessRunner が別プロセスへ stdin で prompt を渡し、
   Coordination が構造化した判断を検証して実行依頼と Solid Queue job を保存する。
5. Execution が確定済みの work snapshot で実行する。後から来たフィードバックを
   実行中の依頼へ混入させず、結果を Coordination に返す。
6. Interaction が返信文を生成し、実 Registry で schema を検証して返信要求を送る。
7. 各層の lifecycle event が実 EventDelivery 行として保存される。
   無作為な canary を環境変数と人間の入力に埋め、入力が AI prompt へ到達しても
   EventLog に残らないことを確認する。token、prompt、生の CLI 出力も保存しない。

外部課題本文・コメント本文が prompt へ到達すること、返信の resource と body、
人間のフィードバックによる直接 dispatch 禁止、実行 lease と immutable snapshot を確認する。

## 障害・並行処理・検索

- 複数 cursor の同時取得、古い lease の完了、重複 job、失敗後の再起動・再 enqueue。
- 親スナップショットの A→B→A の復元、日時だけの更新、古いページの遅延到着、
  ロック待ち中の lease 失効。cursor とイベント／watermark は同じ transaction で確定する。
- EventLog の配信先ごとの再試行、永続化失敗時の業務 transaction 保護、試行回数上限。
- 実 PostgreSQL の advisory lock と別 Ruby プロセス／SIGKILL による配信排他と回復。
- ClickHouse の `FINAL` 重複排除、英語・日本語の検索と index による読み取り絞り込み。
- 管理画面の認証、CSRF、入力 validation、本文 escaping、未設定 provider の選択・保存。

管理画面はローカルブラウザーでも、タスクボード、詳細・構造化実行結果、フィードバック、
provider 設定を確認した。provider の表示は web ローカルの存在診断であり、worker の
subscription login 成功を示すものではない。

## CLI と未実施の確認

Linux の AI image に入る Claude Code 2.1.283 / Codex CLI 0.157.1 について、
実行ファイルの `--version` と利用 flag の `--help` を確認した。
Muse Code の CLI 契約は 1.4.0 の help とログイン不要な echo provider で確認している。
モデルへの実リクエストはテストの対象外。

実サービスの GitHub App / Teams Bot / Jira service account、各 AI subscription login、
Railway への実デプロイ、ngrok での実公開は未実施。運営者の設定後に
[deployment.md](deployment.md) と各 [plugin README](../plugins/README.md) に従って確認する。
API の時刻精度・取得上限・offset pagination の制約、送信後に応答を失った場合の不確実性は
[workflow.md](workflow.md) と各 plugin README に記載している。
