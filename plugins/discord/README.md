# Discord プラグイン

Discord 用の in-process プラグイン。Bot トークンによる認証で Discord REST
API v10（固定 origin `https://discord.com`）を使い、許可チャネルでの Bot
へのメンション取得と、元投稿への返信・チャネル通知を行う。
`create_issue` は非対応とし、課題作成は GitHub プラグインで行う。

## 認証情報（DB の Discord アカウント）

Bot アカウントのトークン（Bot 認証のみ）を管理画面のアカウントページで
設定する。環境変数では渡さない。アダプターが受け取る環境形ハッシュの
キーは `DISCORD_BOT_TOKEN` のまま。

ユーザートークン・OAuth 委任・webhook 資格情報は使わない。Bot ID の設定
は不要で、トークンで認証した `GET /users/@me` から自己 ID を確認する。
poll・送信の可否は DB アカウントの設定有無で判定する。トークン値は
catalog・ログ・管理画面・AI 入力・子プロセス環境へ出さない。

## 最小権限・セットアップ

1. [Discord Developer Portal](https://discord.com/developers/applications)
   で Application を作り、Bot を追加してトークンを取得する。Privileged
   Gateway Intent は不要（後述）。
2. OAuth2 URL Generator で `bot` スコープとテキスト権限
   `VIEW_CHANNEL`・`READ_MESSAGE_HISTORY`・`SEND_MESSAGES` を選び、対象
   サーバーへ Bot を招待する。
3. 対象チャネルで Bot が上記権限を持つことを確認する。プライベートチャネル
   では Bot ロールへ明示の閲覧許可が必要。
4. チャネル ID を取得する（Discord 設定で開発者モードを有効化し、チャネルを
   右クリックして「ID をコピー」）。
5. 管理画面のアカウントページで Bot トークンを設定し、poll / 送信の
   allowlist `AICONSHELL_ALLOWED_SCOPES=discord:channel/<channelId>` を設定する。
6. 対象チャネルで Bot にメンション付きで投稿し、Task が作られることを確認する。

スレッド内の取得・投稿は、そのスレッド ID を `channel/<threadId>` として
allowlist へ設定した範囲で行う。新規スレッド作成は対象外。既存スレッドへの
投稿はチャネルと同様 `SEND_MESSAGES` で行い、スレッドの作成・復元に必要な
追加権限（`CREATE_PUBLIC_THREADS` 等）は本プラグインでは使わない。

## メッセージ内容（MESSAGE_CONTENT）とメンション受付

Bot は既定で、構造化 `mentions` に自身の Bot ID を含む人間の投稿のみ
受付する。本文文字列だけの擬似メンション（`<@id>` と書いただけ等）、
他 Bot へのメンション、通常発言、自己 / Bot / webhook / system 投稿は
イベントにせず、新しい Task を起動しない。返信ループ防止のため、Bot 自身の
投稿（`author.bot`）も取り込まない。Bot ID は本文から推測せず、必ず
`/users/@me` の応答を使う。受付けたメンション本文はそのまま人間の依頼
データとして保持する（メンション記法の除去はしない）。

Discord の Message Content Intent には例外があり、Bot へのメンションを
含むメッセージと DM は intent なしでも内容が取得できる。本プラグインは
メンション投稿のみ取り込むため、Privileged Intent の有効化は不要である。
メンションを含まない投稿の本文が空で返る場合も、その投稿は受付対象外の
ため動作に影響しない。公式資料:

- https://docs.discord.com/developers/resources/message
- https://docs.discord.com/developers/resources/user
- https://docs.discord.com/developers/topics/permissions
- https://docs.discord.com/developers/topics/rate-limits
- https://docs.discord.com/developers/events/gateway

## 操作

- `latest_events`: `GET /channels/{channel.id}/messages` を `limit=100` で
  新しい順に取得する。新規メッセージが 100 件を超える場合は `before` で
  過去へページングし、全取得後に cursor より新しいイベントを返す。
  毎回、先頭ページ（最新 100 件）は cursor にかかわらず再取得するため、
  直近の編集は fingerprint の改訂として取り込める。cursor は
  `{"after": "<snowflake>"}` のみで、`after` は観測した最大メッセージ ID
  （受付対象外の投稿を含む）へ進む。
- `reply`: `POST /channels/{channel.id}/messages` に
  `message_reference: {message_id}` を付けて元投稿へ返信する。
  `resource_id` は `message:<channelId>/<messageId>`。
- `send_message`: 同 endpoint へ通常投稿する。`scope` は
  `channel:<channelId>`。チャネル・スレッドの新規作成は対象外。
- `create_issue`: 非対応。catalog では `unsupported: true` で公開し、
  呼び出すと `UnsupportedOperation` になる。
- `health_check`（`read_only: true`）: `GET /users/@me` で疎通確認し、
  `{"ok": true, "bot_id": "..."}` を返す。入力は `{}`。管理画面の接続確認
  から使い、AI の型付き読み取り対象にはしない（scope を持たないため
  allowlist 検証で拒否される）。

書き込み本文は Discord の上限に合わせ 1–2000 文字のみ受付し、超過・空・
不正な本文は HTTP 送信前に `InputInvalid` として拒否する。拒否は送信開始
前なので、永続 OutboundAction が `uncertain` になることはない。複数 POST
への暗黙分割は行わず、部分成功や重複を隠さない。通知本文には常に
`allowed_mentions: {parse: [], replied_user: false}` を付け、ユーザー /
role / everyone への意図しない ping を防ぐ。返信先が消失した場合
（404 等）は通常投稿へ fallback せず失敗させる。書き込み結果の `url` は
`null`（Discord の投稿応答に閲覧 URL は含まれない）。

`event_id` は `discord:message:<channelId>/<messageId>` で、複数チャネル
間の衝突を防ぐ。`resource_id` は `message:<channelId>/<messageId>`。
`occurred_at` は作成時刻ではなく今回観測した更新時刻（`edited_timestamp`
があればそちら）を表し、編集の改訂契約へ接続する。本文編集は fingerprint
で区別し、A→B→A の往復も改訂として取り込む。

## Incomplete polls

メッセージ一覧は最大 10 ページ（最大 1000 件）。ページ上限に達しても未取得
分が残る場合や、pagination が進行しない場合、不正な応答・途中失敗では
`IncompletePoll` 等で失敗し、部分的な events / cursor は返さない。
保存済み cursor を保持し、データを永続化しないまま先へ進めないこと。

初回取込の範囲は最新最大 1000 件である。停止中のバックログがそれを超える
場合は `IncompletePoll` で失敗するため、狭いチャネル分割やバックログ解消
後の再試行で対応する。最近の編集の再取得範囲は、毎回取得する先頭ページ
（最新 100 件）と前回 cursor 以降の新規分である。それより古い編集や削除は
一覧 API で保証できないため取り込めない。

## 制約

- Gateway 常時接続、Slash commands、チャネル / スレッドの自動発見・作成、
  DM 相手探索、音声、添付ファイル取得、ユーザー代理認証は対象外。
- 429（`Retry-After` が有限小数の場合も含む）は `RateLimited` として返し、
  呼び出し側の bounded retry に任せる。401 / 403 は `HttpError` とし、
  自動再送の対象にしない。timeout・不正な成功応答は型付きエラーとし、
  トークン・本文・生応答をメッセージへ含めない。
- 一覧・投稿の host は固定 origin のみで、cursor や応答内の URL 追跡はしない。
- 投稿成功直後に呼び出し側が停止すると、再試行で重複投稿が起こり得る。
  exactly-once は保証しない。

検証は fake transport による単体テストと、実 Registry に対する結合テスト。
実サーバーの Bot 作成・招待・投稿確認は別途必要。
