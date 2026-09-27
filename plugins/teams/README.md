# Teams プラグイン

Microsoft Teams 用の in-process プラグイン。読み取りは Microsoft Graph
（application 権限）、書き込みは Bot Connector（proactive messages）を使う。
通常投稿に Graph の import / migration API は使わない。
Teams に issue tracker はないため `create_issue` は非対応とし、
課題作成は GitHub / Jira プラグインで行う。

## 運用名義

本プラグインは Graph application + Bot 名義の Bot 運用である（下記のアプリ資格情報）。
同意した特定ユーザー名義で動く OAuth2 代理運用とは別の接続であり、
管理画面の「OAuth連携」で管理する。個人 PAT による代理運用・PAT 入力・
OAuth 失敗時の PAT fallback は提供しない。詳しくは [OAuth接続](../../docs/oauth-connections.md) を参照。

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
| `TEAMS_BOT_TARGETS_FILE` | Graph resource への書き込み時に必須（context で代替可） | 実際の Bot conversation / activity 参照を対応付ける private JSON ファイル |

`catalog` の `configured` は読み取り資格情報のみで判定する。
書き込み資格情報の不足は `reply` / `send_message` 実行時に
`CredentialsMissing` として失敗する。

## 最小権限

- Graph（読み取り）: 対象チームの resource-specific consent を使う
  application 権限 `ChannelMessage.Read.Group`。テナント全体で許可する構成は
  `ChannelMessage.Read.All` と管理者同意を使う。
  `Channel.Create` / `Chat` 系 / import 系は不要。
- Bot（書き込み）: Azure Bot resource を作成し、Teams channel を有効化して
  対象チームにアプリを install する。Graph 書き込み権限は使わない。

## セットアップ

1. Entra アプリを作成し、上記の Graph 読み取り権限を設定する。
2. Azure Bot を作成し（多くの場合 1 と同じアプリ）、Teams channel を有効化する。
3. アプリマニフェストで bot を定義し、対象チームに install する。
4. 信頼された Bot の受信処理で得た `serviceUrl` と conversation / activity 参照を保持する。
   対象のスレッド参照は受信 activity または Bot の conversation 作成結果から取得する。
   `TEAMS_SERVICE_URL` はその参照の https URL に設定する。
5. Graph の team / channel / root message と対応が確認できた Bot 参照を、下記ファイルへ設定する。
   install イベントだけで全スレッドの参照が揃うわけではない。
6. poll の `scope` は `team/<teamId>/channel/<channelId>`。
   team / channel ID は対象テナントの Graph で確認する。

## 操作

- `latest_events`: `GET /v1.0/teams/{id}/channels/{id}/messages`
  と各 root の `/replies` を `$top=50` で全ページ取得する。
  Graph のこれらの一覧 API は `$filter` をサポートしない。
  root の順序は返信を含むスレッド全体の更新順なので、root 自体が古くても
  返信を取得する。`@odata.nextLink` の https origin（scheme・host・port）を検証する。
  全走査後に、各メッセージの更新時刻を用いて cursor より 5 分前までのイベントを返す。
- `reply`: `resource_id` は `message:<teamId>/<channelId>/<rootMessageId>`、
  `channel:<teamId>/<channelId>`、または実際の Bot 参照 `conversation:<id>[/<activityId>]`。
  `message:` / `channel:` は下記の信頼された対応表で解決する。
  activity ID がある場合は `POST {serviceUrl}/v3/conversations/{id}/activities/{activityId}`
  へ投稿する。activity ID がない conversation 参照は `/activities` へ投稿する。
- `send_message`: `scope` は `channel:<teamId>/<channelId>` または `conversation:<id>[/<activityId>]`。
  対応先の既存 conversation へ送信する。conversation の新規作成はこのプラグインの対象外。
  明示の参照または対応表で activity を指定した場合は、その activity への返信となる。
- `create_issue`: 非対応。catalog では `unsupported: true` で公開し、
  呼び出すと `UnsupportedOperation` になる。

cursor は `{"since": "ISO8601"}` のみ。厳密なタイムゾーン付き日時を解析し、
実時刻で比較して UTC に正規化する。`cursor.next` は部分走査の水位を失うため受け付けない。
全ページ取得に失敗した場合は例外となり、events / cursor を返さない。
呼び出し側は全イベントの永続保存後だけ cursor を更新すること。

root と返信の `resource_id` は同じ `message:<teamId>/<channelId>/<rootMessageId>`。
`event_id` は team・channel・root（返信時）・個々の message ID を含むため別 scope と衝突しない。
各部分は percent encoding し `/` で区切る。本文編集は fingerprint で区別する。
`occurred_at` は作成時刻ではなく今回観測した更新時刻を表す。

## Bot 参照の対応表

`TEAMS_BOT_TARGETS_FILE` の例（値は受信済みの実際の参照で置き換える）:

```json
{
  "channel:team-1/channel-1": {
    "conversation_id": "actual-bot-conversation-id"
  },
  "message:team-1/channel-1/root-message-id": {
    "conversation_id": "actual-bot-thread-conversation-id",
    "activity_id": "actual-root-bot-activity-id"
  }
}
```

同じオブジェクトを信頼されたアプリコードから `context["teams_bot_targets"]` に渡してもよい。
context 指定がファイルより優先する。JSON Schema で値を検証し、未設定・不正・対象不在の場合は
外部 I/O の前に `CredentialsMissing` を送出する。`message:` の返信には `activity_id` が必須。
Graph の ID から Bot の ID やスレッド ID を生成しない。
対応表は private mount へ配置し、Git や AI workspace へ入れない。
人間のメッセージ本文、Graph payload、未検証の受信 activity を設定として扱わない。
このアダプターは Bot 受信 webhook や Graph-to-Bot 対応表を自動作成しない。

## Incomplete polls

root 一覧と各 root の返信一覧はそれぞれ最大 25 ページ。
50 件で展開を打ち切る制限はない。ページ上限に達しても次ページが残る場合や
pagination loop では `IncompletePoll` とし、部分的な events / cursor は返さない。
保存済み cursor を保持し、データを永続化しないまま先へ進めないこと。

同じチャネルで常に上限を超える場合は取り込みを停止し、負荷・Graph のレート制限を
評価して `MAX_PAGES` の変更をテストするか、永続的な途中再開を実装してから再試行する。
全スレッドを走査するため、cursor を新しくすることや単なる再試行では恒常的な上限超過は解消しない。

## 制約

- チャネルの全スレッドと返信を走査するため、履歴の件数に応じて API 呼び出しが増える。
- Graph の一覧はスナップショットではない。5 分を超える遅延や後から可視になった古いイベントは
  以前の cursor からの再照合が必要。削除済みイベントの回収は保証しない。
- token 取得失敗・Graph / Bot 側の 429 はそれぞれ `HttpError` / `RateLimited`
  として返す。呼び出し側で待機・再試行すること（Bot Connector の throttle）。
- Bot Connector 応答に投稿 URL は含まれないため、書き込み結果の `url` は `null`。
- `TEAMS_SERVICE_URL` 以外の host へ書き込み要求は送らない。
- Graph / service URL は https のみで、userinfo・query・fragment を含む設定を拒否する。
- 投稿成功直後に呼び出し側が停止すると、再試行で重複投稿が起こり得る。exactly-once は保証しない。

検証は fake transport による単体テスト。実テナントの認証・Bot 参照の対応・投稿確認は別途必要。

## 公式ドキュメント

- https://learn.microsoft.com/en-us/graph/api/channel-list-messages
- https://learn.microsoft.com/en-us/graph/api/chatmessage-list-replies
- https://learn.microsoft.com/en-us/graph/teams-licenses
- https://learn.microsoft.com/en-us/microsoftteams/platform/bot-basics
- https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/conversations/send-proactive-messages
- https://learn.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-connector-send-and-receive-messages
- https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-client-creds-grant-flow
