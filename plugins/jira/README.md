# Jira プラグイン

Jira Cloud 用の in-process プラグイン。service account のメールアドレス +
API token（Basic 認証）で動作する。Enhanced JQL（POST `/rest/api/3/search/jql`）
で課題を取得し、課題ごとに comments と changelog を paging する。
本文は Atlassian Document Format（ADF）として送受信する。

## 必要な環境変数

| 変数 | 必須 | 説明 |
| --- | --- | --- |
| `JIRA_EMAIL` | 必須 | service account のメールアドレス |
| `JIRA_API_TOKEN` | どちらか必須 | API token |
| `JIRA_API_TOKEN_FILE` | どちらか必須 | API token を格納した private ファイルのパス |
| `JIRA_SITE_URL` | いずれか必須 | `https://<site>.atlassian.net` |
| `JIRA_CLOUD_ID` | いずれか必須 | Cloud ID。`https://api.atlassian.com/ex/jira/<cloudId>` を使う |
| `JIRA_BASE_URL` | いずれか必須 | 明示のベース URL（優先度最高） |
| `JIRA_SERVICE_ACCOUNT_ID` | アプリ経由の書き込み時に必須（代替設定あり） | service account の Atlassian `accountId`。自己投稿の再取り込みを抑制する |

`JIRA_SERVICE_ACCOUNT_ID` は `GET /rest/api/3/myself` 等で確認した ID を設定する。
共通設定 `AICONSHELL_SELF_ACTOR_IDS` の `jira` エントリでも指定できる。
Interaction の書き込みサービスは自己 actor ID 未設定の送信を拒否する。
API token のメールアドレスだけでは投稿者を安全に識別できない。
`catalog.configured` は読み取りの資格情報の指定有無を示すもので、権限や有効期限の検査ではない。

エンドポイントの優先順位は `JIRA_BASE_URL` > `JIRA_SITE_URL` > `JIRA_CLOUD_ID`。
`JIRA_CLOUD_ID` 指定時は scoped token 用 host（`api.atlassian.com/ex/jira/...`）を使う。
ベース URL は https のみ許可し、userinfo・query・fragment を含む URL は拒否する。

## 最小権限

- service account（Atlassian アカウント）に、対象プロジェクトの
  Browse Projects / Create Issues / Add Comments を付与する。
- Jira 管理者権限やサイト管理 API scope は不要。
- API token は対象アカウントの https://id.atlassian.com/manage-profile/security/api-tokens で発行する。

## セットアップ

1. service account 用の Atlassian アカウントを用意し、対象プロジェクトに招待する。
2. API token を発行し、アプリ実行環境の ENV か private ファイルに配置する。
3. `JIRA_SITE_URL`（または Cloud ID / ベース URL）を設定する。
4. service account の Jira タイムゾーンを **UTC** に設定する。
   JQL の日時はアカウントの設定タイムゾーンで評価されるため、UTC 以外の設定は非対応。
5. 書き込みを使う場合は上記の自己 actor ID を設定する。
6. `scope` は Jira プロジェクトキー（例 `PROJ`）。全プロジェクトの `*` は
   `cursor.since` 指定時のみ受け付ける。Enhanced JQL は検索条件のない一覧を許可しないため、
   初回取り込みはプロジェクト別に実行する。

`*` は polling 用。Interaction の送信先 allowlist は完全一致で確認するため、
書き込みには具体的なプロジェクトキーを許可すること。

## 操作

- `latest_events`: cursor を厳密な ISO8601 の日時として解析し、UTC に変換する。
  5 分の重複期間を設けて `updated >= "YYYY-MM-DD HH:mm" ORDER BY updated ASC`
  を実行する。cursor の文字列を JQL に直接挿入しない。
  コメント編集が親課題の `updated` を変更する前提を置かず、同じ境界の
  `updated < "YYYY-MM-DD HH:mm"` も走査する。初回は対象 scope 全体を走査する。
  Enhanced JQL は `nextPageToken`、comments / changelog は
  `startAt`・`maxResults`・`total`（および返却時の `nextPage`）に従って全ページを取得する。
  各イベントの更新時刻で重複期間より古いものを除外する。
- `reply`: `resource_id` は `issue:PROJ-123`。本文は段落 ADF に変換して投稿する。
- `create_issue`: `scope` はプロジェクトキー。issue type は `Task` 固定。

cursor は `{"since": "ISO8601"}` のみ。時刻はオフセットを含む実時刻として比較し、
返却値は UTC に正規化する。同じ時刻のイベントも再取得し、本文編集は fingerprint で区別する。
comment の actor は `updateAuthor`（なければ `author`）を使う。
全走査が成功した場合だけ cursor を返す。呼び出し側は全イベントの永続保存後に cursor を更新すること。
API が返す `nextPage` の scheme・host・port が設定 origin と異なる、または
userinfo を含む場合は要求を送らず `HostRejected` として失敗する。

## Incomplete polls

検索の各 partition、各課題の comments / changelog はそれぞれ最大 25 ページ。
50 件で課題を切り捨てる制限はない。25 ページ目に続きがある、offset が進まない、
全件取得前に空ページになる場合は `IncompletePoll` を送出する。
部分的な events / cursor は返さず、保存済み cursor を保持する。

繰り返し上限に達する場合、`*` はプロジェクト別の scope に分ける。
単一プロジェクトまたは単一課題でも上限を超える場合は、その scope の取り込みを停止し、
負荷・レート制限を評価したうえで `MAX_PAGES` の上限を変更してテストするか、
永続的な途中再開を実装してから再試行する。古い課題も毎回照合するため、
cursor を現在時刻へ進めることや単なる再試行では恒常的な上限超過は解消しない。

## 制約

- 全対象課題の子リソースを走査するため、課題・コメント・履歴の件数に応じて API 呼び出しが増える。
- Jira の検索はスナップショットではない。5 分を超える遅延、権限変更で後から可視になった古いイベント、
  削除済みイベントの回収は保証しない。必要時は以前の cursor または初回 cursor から再照合する。
- description / comment は ADF の text・paragraph・list・table・mention・emoji・
  media・card を簡易抽出する。複雑なマクロや code block の書式は失われる。
- `create_issue` は summary・description・Task 固定。必須カスタムフィールドが
  あるプロジェクトでは作成が 400 になるため、Jira 側で必須項目を外すか別手段を使う。
- scoped host（`api.atlassian.com`）利用時は `url` を返せないため `null` になる。
- 429 は `RateLimited`（`retry_after` 付き）として返す。呼び出し側で待機・再試行すること。
- 投稿成功直後に呼び出し側が停止すると、再試行で重複投稿が起こり得る。exactly-once は保証しない。

検証は fake transport による単体テスト。実アカウントの認証・投稿・権限確認は別途必要。

## 公式ドキュメント

- https://developer.atlassian.com/cloud/jira/platform/rest/v3/intro/
- https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-search/#api-rest-api-3-search-jql-post
- https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-comments/
- https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/#api-rest-api-3-issue-issueidorkey-changelog-get
- https://support.atlassian.com/jira-software-cloud/docs/jql-fields/#Updated
- https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/#api-rest-api-3-issue-post
- https://developer.atlassian.com/cloud/jira/platform/apis/document/structure/
- https://developer.atlassian.com/cloud/jira/platform/basic-auth-for-rest-apis/
- https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/
