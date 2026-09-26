# Jira プラグイン

Jira Cloud 用の in-process プラグイン。service account のメールアドレス +
API token（Basic 認証）で動作する。Enhanced JQL（POST `/rest/api/3/search/jql`）
で更新課題を取得し、課題ごとに comments と changelog を paging する。
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

エンドポイントの優先順位は `JIRA_BASE_URL` > `JIRA_SITE_URL` > `JIRA_CLOUD_ID`。
`JIRA_CLOUD_ID` 指定時は scoped token 用 host（`api.atlassian.com/ex/jira/...`）を使う。
ベース URL は https のみ許可する。

## 最小権限

- service account（Atlassian アカウント）に、対象プロジェクトの
  Browse Projects / Create Issues / Add Comments を付与する。
- Jira 管理者権限やサイト管理 API scope は不要。
- API token は対象アカウントの https://id.atlassian.com/manage-profile/security/api-tokens で発行する。

## セットアップ

1. service account 用の Atlassian アカウントを用意し、対象プロジェクトに招待する。
2. API token を発行し、アプリ実行環境の ENV か private ファイルに配置する。
3. `JIRA_SITE_URL`（または Cloud ID / ベース URL）を設定する。
4. `scope` は Jira プロジェクトキー（例 `PROJ`）、全プロジェクトは `*`。

## 操作

- `latest_events`: Enhanced JQL `updated >= "<since>" ORDER BY updated ASC`
  （`nextPageToken` で paging）→ 課題ごとに
  `/issue/{key}/comment` と `/issue/{key}/changelog` を `nextPage` で paging。
  失敗時は例外を送出し、cursor は前進させない。
- `reply`: `resource_id` は `issue:PROJ-123`。本文は段落 ADF に変換して投稿する。
- `create_issue`: `scope` はプロジェクトキー。issue type は `Task` 固定。

cursor は `{"since": "ISO8601"}` のみ（JSON serializable）。
API が返す `nextPage` URL の host が設定 host と異なる場合は要求を送らず
`HostRejected` として失敗する。

## 制約

- 1 回の poll で展開する課題は最大 50 件、1 エンドポイントのページ追跡は最大 25。
- description / comment は ADF の text・paragraph・list・table・mention・emoji・
  media・card を簡易抽出する。複雑なマクロや code block の書式は失われる。
- `create_issue` は summary・description・Task 固定。必須カスタムフィールドが
  あるプロジェクトでは作成が 400 になるため、Jira 側で必須項目を外すか別手段を使う。
- scoped host（`api.atlassian.com`）利用時は `url` を返せないため `null` になる。
- 429 は `RateLimited`（`retry_after` 付き）として返す。呼び出し側で待機・再試行すること。

## 公式ドキュメント

- https://developer.atlassian.com/cloud/jira/platform/rest/v3/intro/
- https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-search/#api-rest-api-3-search-jql-post
- https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-comments/
- https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/#api-rest-api-3-issue-post
- https://developer.atlassian.com/cloud/jira/platform/apis/document/structure/
- https://developer.atlassian.com/cloud/jira/platform/basic-auth-for-rest-apis/
- https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/
