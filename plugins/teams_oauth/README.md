# Teams OAuth プラグイン（同意ユーザー代理）

Microsoft Teams 用の in-process プラグイン。同意した特定ユーザーとして
Microsoft Graph（委任権限）のみを使い、既存チャネル・既存チャットを読み書きする。
Bot 設定・Bot Connector・application 権限（`TEAMS_*`）は使わず、
未接続時の Bot / app 権限への fallback も行わない。

## 運用の区別（Bot 名義 / OAuth 代理 / PAT 禁止）

このリポジトリの Teams 運用は次の2種類のみである。

1. 既存サービスアカウント / Bot 名義の Bot 運用（`teams` プラグイン）。
   Graph application 権限で読み、Bot Connector で書き込む。
2. 同意した特定ユーザー名義の OAuth2 代理運用（本プラグイン `teams_oauth`）。
   委任 Graph API のみで読み書きし、Bot 設定を要求しない。

個人 PAT による代理運用・PAT 入力 UI・PAT 専用 plugin・OAuth 失敗時の
個人 PAT fallback は追加しない。既存サービスアカウントの認証設定と
個人 PAT 運用を混同せず、導入時はどちらの名義・どちらの認証で動くかを明示すること。

## 必要な環境変数

| 変数 | 必須 | 説明 |
| --- | --- | --- |
| `OAUTH_MICROSOFT_CLIENT_ID` | 必須 | Entra アプリ（クライアント）ID |
| `OAUTH_MICROSOFT_CLIENT_SECRET` | どちらか必須 | Entra アプリのクライアントシークレット |
| `OAUTH_MICROSOFT_CLIENT_SECRET_FILE` | どちらか必須 | 上記を格納した private ファイルのパス |
| `OAUTH_MICROSOFT_TENANT_ID` | 必須 | 固定の Entra テナント（work / school account。`common` / `organizations` / `consumers` 不可） |
| `OAUTH_MICROSOFT_REDIRECT_URI` | 必須 | 固定の OAuth redirect URI（https） |

`catalog` の `configured` は上記の設定有無のみで判定する。
接続成功との区別（未接続・再接続が必要など）は管理画面側が表示する。
既存 service account 用の `TEAMS_*` とは独立した変数であり、混在・転用しない。

## 最小権限（委任 scope）

同意・テナント設定は OAuth 接続基盤（`docs/oauth-connections.md`）を使う。
本プラグインが必要とする委任 scope は次のとおり。

- `User.Read`（同意ユーザーの確認）
- `ChannelMessage.Read.All` / `ChannelMessage.Send`（チャネル読み書き）
- `Chat.Read` / `ChatMessage.Send`（チャット読み書き）
- `offline_access`（refresh token 要求。API 権限ではない）

Bot 関連権限・migration / import 系・`Group.ReadWrite.All` は使わない。

## セットアップ

1. Entra アプリを作成し、固定テナント・redirect URI・上記 scope を設定する。
2. 管理画面の OAuth 接続手順で同意ユーザーを接続する（work / school account）。
3. poll の `scope` は `team/<teamId>/channel/<channelId>`（チャネル）または
   `chat/<chatId>`（チャット）。ID は対象テナントの Graph で確認する。
4. 書き込みの `scope` は `channel:<teamId>/<channelId>` または `chat:<chatId>`。
   チャネルへの返信の `resource_id` は `message:<teamId>/<channelId>/<rootId>`、
   チャットへの返信は `chat_message:<chatId>/<messageId>`。

## 操作

Graph ベース URL は `https://graph.microsoft.com/v1.0` に固定する。
設定による変更・別 origin への送信は行わない。

| 操作 | 入力 | Graph 呼び出し |
| --- | --- | --- |
| `latest_events`（read_only） | `scope` + `cursor` | チャネル: `GET /v1.0/teams/{id}/channels/{id}/messages` と各 root の `/replies` を `$top=50` で全ページ取得。チャット: `GET /v1.0/chats/{id}/messages` を全ページ取得 |
| `reply` | `resource_id` + `body` | チャネル: `POST .../messages/{rootId}/replies`。チャット: `POST /v1.0/chats/{id}/messages`（新規メッセージ。チャットにスレッド返信 API はないため捏造しない） |
| `send_message` | `scope` + `body` | チャネル: `POST .../messages`。チャット: `POST /v1.0/chats/{id}/messages` |
| `create_issue` | — | 非対応。catalog では `unsupported: true` で公開し、呼び出すと `UnsupportedOperation` になる |

- 投稿本文はテキストのみ（`contentType: text`）。`from` を送らず、送信者を偽装しない。
- 受信イベントの `actor` は Graph の `from` を正規化する（`user` → `human`、
  `application` → `bot`、その他 → `system`）。
- 新規チャット作成・メンバー追加・DM 相手探索は対象外。
- Graph の一覧 API は `$filter` を使わない。root の順序は返信を含むスレッド全体の
  更新順なので、root 自体が古くても返信を取得する。
- `@odata.nextLink` は https origin の一致だけでなく、走査中の collection path と
  完全一致する場合のみ追従する。別チャネル・別チャット・別メッセージ・別ページへの
  link や fragment 付き link は追従せず型付きエラーとする。
- 各 ID は単一の Graph path segment として検証・percent encoding する。
  `/`・`\`・空白・制御文字・`.`・`..` を含む ID は path traversal 防止のため拒否する。

cursor は `{"since": "ISO8601"}` のみ。厳密なタイムゾーン付き日時を解析し、
実時刻で比較して UTC に正規化する。全ページ取得に失敗した場合は例外となり、
events / cursor を返さない。呼び出し側は全イベントの永続保存後だけ cursor を更新すること。
各メッセージの更新時刻を用い、cursor より 5 分前までのイベントを返す（overlap）。
本文編集・削除は fingerprint で区別する。

チャネル root と返信の `resource_id` は同じ `message:<teamId>/<channelId>/<rootId>`。
チャットの `resource_id` は `chat_message:<chatId>/<messageId>`。
`event_id` は `teams_oauth:` 接頭辞に encoded ID を含み、別 scope・旧 `teams`
プラグインのイベントと衝突しない。
`occurred_at` は作成時刻ではなく今回観測した更新時刻を表す。

書き込み結果の `external_id` は後続の自己投稿照合に使える安定形式である。

- チャネル投稿: `message:<teamId>/<channelId>/<作成メッセージID>`
- チャネル返信: `message:<teamId>/<channelId>/<rootId>/<返信ID>`（先頭は返信先 `resource_id` と一致）
- チャット投稿・返信: `chat_message:<chatId>/<作成メッセージID>`

書き込み結果の `url` は `null`（Graph 応答に投稿 URL は含まれない）。

## Incomplete polls

チャネル root 一覧・各 root の返信一覧・チャット一覧はそれぞれ最大 25 ページ。
ページ上限に達しても次ページが残る場合や pagination loop では `IncompletePoll` とし、
部分的な events / cursor は返さない。保存済み cursor を保持し、
データを永続化しないまま先へ進めないこと。

同じ範囲で常に上限を超える場合は取り込みを停止し、負荷・Graph のレート制限を
評価して `MAX_PAGES` の変更をテストするか、永続的な途中再開を実装してから再試行する。
全スレッドを走査するため、cursor を新しくすることや単なる再試行では恒常的な上限超過は解消しない。

## 信頼された接続の受け渡し

アクセストークンは plugin 入力・AI スキーマに含めない。信頼されたアプリ側が
`context` に次の2値を構築して渡す（後続 #26 が snapshot を固定する）。

- `oauth_binding`：接続基盤の Binding またはその `to_h`（秘密なし）
- `oauth_credential_provider`：`binding_for` / `access_token` ポートを持つ provider

本プラグインは渡された binding をそのまま `access_token(binding)` で解決する。
現在の binding への勝手な取り直し・service account fallback を行わない。
binding / provider の不在・不一致・接続不可は外部 HTTP の前に
`CredentialsMissing` として失敗する。token は検証済みの固定 Graph origin にのみ送る。
テスト用 provider は constructor（`oauth_credential_provider:`）でも注入できる。

## 制約

- 読み書きとも委任 Graph のみ。`TEAMS_*` の読み取り資格・Bot 参照対応表は使わない。
- token 取得失敗・Graph 側の 429 はそれぞれ `CredentialsMissing`（接続不可）/
  `HttpError` / `RateLimited` として返す。呼び出し側で待機・再試行すること。
  書き込みの自動 replay は行わない。
- 投稿成功（API 受理）直後に呼び出し側が停止すると、再試行で重複投稿が起こり得る。
  `sent` は外部 API の受理を示し、人間の閲覧や外部での exactly-once を保証しない。
- Graph は https のみで、userinfo・fragment を含む next link を拒否する。
- 検証は fake transport による単体テスト。実テナントの同意・投稿確認は別途必要。

## 公式ドキュメント

- https://learn.microsoft.com/en-us/graph/api/channel-list-messages?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/graph/api/chatmessage-list-replies?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/graph/api/channel-post-messages?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/graph/api/chat-list-messages?view=graph-rest-1.0
- https://learn.microsoft.com/en-us/graph/api/chat-post-messages?view=graph-rest-1.0
