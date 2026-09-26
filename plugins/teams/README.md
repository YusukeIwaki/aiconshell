# Teams プラグイン

Microsoft Teams 用の in-process プラグイン。読み取りは Microsoft Graph
（application 権限）、書き込みは Bot Connector（proactive messages）を使う。
通常投稿に Graph の import / migration API は使わない。
Teams に issue tracker はないため `create_issue` は非対応とし、
課題作成は GitHub / Jira プラグインで行う。

## 必要な環境変数

| 変数 | 必須 | 説明 |
| --- | --- | --- |
| `TEAMS_TENANT_ID` | 必須 | Entra テナント ID（読み書き共通） |
| `TEAMS_CLIENT_ID` | 必須 | Graph 読み取り用アプリ（クライアント）ID |
| `TEAMS_CLIENT_SECRET` | どちらか必須 | Graph 読み取り用クライアントシークレット |
| `TEAMS_CLIENT_SECRET_FILE` | どちらか必須 | 上記を格納した private ファイルのパス |
| `TEAMS_BOT_APP_ID` | 任意 | Bot 書き込み用アプリ ID。未設定なら `TEAMS_CLIENT_ID` を使う |
| `TEAMS_BOT_APP_PASSWORD` | どちらか必須（書き込み時） | Bot 書き込み用シークレット |
| `TEAMS_BOT_APP_PASSWORD_FILE` | どちらか必須（書き込み時） | 上記を格納した private ファイルのパス |
| `TEAMS_SERVICE_URL` | 必須（書き込み時） | Bot Connector の serviceUrl（https） |
| `TEAMS_GRAPH_URL` | 任意 | Graph ベース URL。既定 `https://graph.microsoft.com` |

`catalog` の `configured` は読み取り資格情報のみで判定する。
書き込み資格情報の不足は `reply` / `send_message` 実行時に
`CredentialsMissing` として失敗する。

## 最小権限

- Graph（読み取り）: application 権限 `ChannelMessage.Read.All` に管理者の同意。
  `Channel.Create` / `Chat` 系 / import 系は不要。
- Bot（書き込み）: Azure Bot resource を作成し、Teams channel を有効化して
  対象チームにアプリを install する。Graph 書き込み権限は使わない。

## セットアップ

1. Entra アプリを作成し、`ChannelMessage.Read.All`（application）に管理者同意する。
2. Azure Bot を作成し（多くの場合 1 と同じアプリ）、Teams channel を有効化する。
3. アプリマニフェストで bot を定義し、対象チームに install する。
4. bot の `conversationUpdate`（install イベント）で通知される `serviceUrl` と
   conversation 参照をアプリ側に保存し、`TEAMS_SERVICE_URL` と書き込み scope
   `conversation:<id>` に使う。channel への新規投稿は channel ID をそのまま
   conversation ID として使える（`channel:<teamId>/<channelId>` 形式も可）。
5. poll の `scope` は `team/<teamId>/channel/<channelId>`。
   team / channel ID は Graph Explorer か
   `GET /v1.0/teams?$select=id,displayName` で確認できる。

## 操作

- `latest_events`: `GET /v1.0/teams/{id}/channels/{id}/messages`
  （`$filter=lastModifiedDateTime gt <since>`）→ メッセージごとに
  `/replies` を取得。`@odata.nextLink` を host 検証付きで追跡する。
  失敗時は例外を送出し、cursor は前進させない。
- `reply`: `resource_id` は `conversation:<id>`（任意で `/<activityId>` を付けて
  thread 返信）または `channel:<teamId>/<channelId>`。
  `POST {serviceUrl}/v3/conversations/{id}/activities` で投稿する。
- `send_message`: `scope` は reply と同じ 2 形式。新規メッセージとして投稿する。
- `create_issue`: 非対応。catalog では `unsupported: true` で公開し、
  呼び出すと `UnsupportedOperation` になる。

cursor は `{"since": "ISO8601"}` が基本（JSON serializable）。
`cursor.next` に Graph の次ページ URL を渡すとそこから再開するが、
host は Graph host のみ許可する。

poll で得られる event の `resource_id` は `message:<teamId>/<channelId>/<messageId>`
形式で、Graph 側の ID 体系のため Bot Connector へはそのまま渡せない。
書き込み対象の conversation 参照は install イベント等で取得してアプリ側で保持し、
event payload の `team_id` / `channel_id` / `message_id` と対応付けること。

## 制約

- 1 回の poll で展開するメッセージは最大 50 件、1 エンドポイントのページ追跡は最大 25。
- token 取得失敗・Graph / Bot 側の 429 はそれぞれ `HttpError` / `RateLimited`
  として返す。呼び出し側で待機・再試行すること（Bot Connector の throttle）。
- Bot Connector 応答に投稿 URL は含まれないため、書き込み結果の `url` は `null`。
- `TEAMS_SERVICE_URL` 以外の host へ書き込み要求は送らない。

## 公式ドキュメント

- https://learn.microsoft.com/en-us/graph/api/channel-list-messages
- https://learn.microsoft.com/en-us/graph/api/chatmessage-list-replies
- https://learn.microsoft.com/en-us/graph/teams-licenses
- https://learn.microsoft.com/en-us/microsoftteams/platform/bot-basics
- https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/conversations/send-proactive-messages
- https://learn.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-connector-send-and-receive-messages
- https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow
