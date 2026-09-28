# 設計資料の入口

新しい実装セッションは GitHub Issue とこのリポジトリを入力にする。
Issue は「今回何を変えるか」、以下の資料は「継続して守る契約」を表す。
作業の進め方は [Issue 開発手順](issue-development.md)、テストは [testing.md](testing.md)。
設計変更の前には [architecture.md](architecture.md) を読む。

## 変更する領域から読む

| 変更するもの | 正となる資料 | 主なコード / 回帰テスト |
| --- | --- | --- |
| 管理画面・APIからの依頼、受付と重複 | [task-requests.md](task-requests.md)、[admin.md](admin.md) | `app/services/interaction/`、`app/controllers/{admin,api}/`、`smartest/integration/acceptance/` |
| タスク状態・優先度・dispatch・外部送信 | [workflow.md](workflow.md) | `app/services/{interaction,coordination,execution}/`、`smartest/integration/workflow/` |
| GitHub / Teams / Jira / Discord の操作 | [architecture.md の Plugins](architecture.md#plugins)、[各 plugin README](../plugins/) | `lib/aiconshell/plugins/`、`plugins/`、`smartest/plugins/` |
| AIの仕事・provider/model/effort・process分離 | [ai-providers.md](ai-providers.md) | `lib/aiconshell/ai/`、`smartest/ai/` |
| AIポリシーの接続表示・ログイン・状態確認 | [ai-connections.md](ai-connections.md)、CLI変更時は [ai-auth-protocol.md](ai-auth-protocol.md) | `Admin::AiStatus`、`AiAuth::RequestService` / `WorkerService`、`AiConnection` / `AiAuthSession`、`smartest/integration/ai_auth/`、`smartest/integration/admin/` |
| ユーザー委任OAuthの接続・token管理 | [oauth-connections.md](oauth-connections.md) | `Aiconshell::Oauth::*`、`Oauth::AuthService` / `TokenService` / `CredentialProvider`、`OauthConnection` / `OauthAuthAttempt`、`smartest/unit/oauth/`、`smartest/integration/oauth/` |
| EventLog・検索・配送 | [event-log.md](event-log.md) | `lib/aiconshell/observability/`、`smartest/{unit,integration}/observability/` |
| Docker・worker queue・Railway・環境分離 | [deployment.md](deployment.md)、[railway-environments.md](railway-environments.md) | `Dockerfile`、`compose.yml`、`config/queue_execution.yml`・`config/queue.yml`、`railway.execution.toml`、`bin/check-compose` |

## 判断を間違えやすい境界

- **業務依頼と運用操作は別。** 人間の仕事の依頼は Interaction の durable ingress →
  Coordination の判断を通る。タスク状態を変えるのは Coordination だけ。
  一方、AI接続確認・ログインは運用操作で、`AiAuth::RequestService` に intent を渡す。
  これに Task/TaskRun、優先度付けや Execution の業務dispatchを流用しない。
- **層とプロセスは一対一ではない。** interaction / coordination / execution の
  3層は単一 execution ワーカー内の分離 pool（control 3 / execution 1 /
  `ai_auth_execution` 1）で動く。接続状態の正は [AIアカウント連携](ai-connections.md)
  （#20）が定める execution の snapshot であり、旧 control の状態を複写しない。
  ポリシーは provider を選ぶ設定であり、接続完了の証拠ではない。
- **Web上でCLIの存在を調べても利用可能性は分からない。** WebはCLIなしの `app` image、
  workerは3つのCLIを持つ `ai` image。Webは worker が保存した接続 snapshot を表示する。
  未設定の provider も選択・保存できる。旧 `Admin::AiStatus.configured?` は互換用であり、
  新しい画面の診断に使用しない。
- **AIや外部本文は権限を決めない。** plugin/AIの両方向のJSON Schema、許可宛先、
  read-only metadata、leaseとversionの検証はRuby側が担う。
  ネットワークやAI待ちの間にDB transactionを保持しない。
- **受付・完了・不明を区別する。** queueへの受付を外部処理の成功と表示しない。
  `waiting_delivery` の確定は reconciler の責務。不確定な送信を自動で再送しない。
- **ログには安全な分類だけ。** EventLogは PostgreSQL outbox → ClickHouse/任意Teams の
  結果整合。層名は interaction / coordination / execution の3つで、controlという層はない。
  認証URL・コード・CLI出力・生例外は記録しない。

上記は資料への案内であり、新しいAPI仕様の定義ではない。
public contract を変えるときは対応する正の資料と境界テストを同じIssueで更新する。
schema・envの正はそれぞれ実装中のJSON Schema、`.env.example` と plugin README。
過去の [検証記録](verification.md) は当時の実測であり、現在の仕様や未実行チェックの代用にはしない。
