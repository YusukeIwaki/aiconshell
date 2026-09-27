# Jira OAuth プラグイン（同意ユーザー代理）

既存 `jira`（service account のメール + API token、Basic 認証）とは別IDの
`jira_oauth`。Atlassian OAuth 2.0 3LO で同意した特定ユーザーとして
課題・コメントを読み書きする。Bearer で
`https://api.atlassian.com/ex/jira/<verified cloudId>/rest/api/3/...` を呼ぶ。
運用方針は次の2種類のみ。個人PATによる代理運用・PAT入力UI・PAT専用plugin・
OAuth失敗時のPAT fallbackは提供しない。

- 既存サービスアカウント/Bot名義のBot運用（`plugins/jira/README.md`）
- 同意した特定ユーザー名義のOAuth2代理運用（本README）

 service account の認証設定と個人PAT運用を混同しないこと。名義と認証の区別は
UI表示と本READMEで行う。

## 必要な環境変数

`JIRA_*` とは独立。混在・転用しない。

| 変数 | 必須 | 説明 |
| --- | --- | --- |
| `OAUTH_ATLASSIAN_CLIENT_ID` | 必須 | Atlassian OAuth app の client ID |
| `OAUTH_ATLASSIAN_CLIENT_SECRET` | どちらか必須 | client secret |
| `OAUTH_ATLASSIAN_CLIENT_SECRET_FILE` | どちらか必須 | secret を格納した private ファイルのパス |
| `OAUTH_ATLASSIAN_CLOUD_ID` | 必須 | 操作対象の1 cloud ID（固定） |
| `OAUTH_ATLASSIAN_REDIRECT_URI` | 必須 | 登録済み固定 redirect URI（https。明示設定の loopback http のみ可） |

`catalog.configured` は上記設定の有無のみを示す。接続成功との区別は
管理画面（#23）・業務統合（#26）が表示する。未接続時に service account へ
fallbackしない。

## 必要scope（Atlassian同意画面）

`offline_access` `read:jira-work` `write:jira-work` `read:jira-user`

`offline_access` は refresh token 取得のための付与フラグであり、
API権限ではない。対象プロジェクトには同意ユーザーに対して
Browse Projects / Create Issues / Add Comments を付与する。
Jira管理者権限やサイト管理API scopeは不要。

## セットアップ

1. Atlassian developer console で OAuth 2.0 (3LO) app を作り、上記 redirect URI
   を登録する。要求scopeは上記の4つ。
2. 運用環境に `OAUTH_ATLASSIAN_*` を配置する（値やsecretをリポジトリに置かない）。
3. 管理画面（#23）から同意ユーザーを接続する。検証は accessible-resources で
   固定cloud IDとJira権限を確認し、同cloudの `/myself` で `accountId` を確定する。
4. 業務フロー（#26）が接続ID・世代・principal・cloudのsnapshotを固定し、
   信頼された `oauth_binding` / `oauth_credential_provider` として渡す。
5. `scope` は具体的なJiraプロジェクトキー（例 `PROJ`）のみ。全プロジェクト `*`
   は初版対象外で明示拒否する。書き込みの送信先allowlistも具体キーで許可すること。

## 操作

- `latest_events`（`jira_oauth:read`、read_only）: 入力 `{"scope": "PROJ",
  "cursor": null または {"since": ISO8601}}`。Enhanced JQL
  `project = PROJ ORDER BY updated ASC`（時間述語なし）で対象プロジェクト全体を
  bounded pagingし、取得後にISO8601の実時刻でcursorフィルターする。
  5分の重複期間を設け、同じ時刻の再取得とfingerprintによる編集区別を行う。
  初回（cursorなし）は対象scope全体を走査する。`scope: "*"` は受け付けない。
- `reply`（`jira_oauth:write`）: 入力 `{"resource_id": "issue:PROJ-123",
  "body": "..."}`。本文は段落ADFに変換して投稿する。
- `create_issue`（`jira_oauth:write`）: 入力 `{"scope": "PROJ", "title": "...",
  "body": "..."}`。issue typeは `Task` 固定。

permissionは独立した `jira_oauth:read` / `jira_oauth:write`。
既存 `jira:read` / `jira:write` とは互換性がなく、資格情報・allowlist・IDを混在させない。

cursorは `{"since": "ISO8601"}` のみ。返却値はUTCに正規化する。
全走査が成功した場合だけcursorを返す。呼び出し側は全イベントの永続保存後に
cursorを更新すること。

受信event IDと送信external_idは安定形式で、アプリの自己投稿照合に使える。
`jira:issue:<KEY>` / `jira:comment:<id>` / `jira:changelog:<issueId>:<changeId>`、
`reply` の `external_id` はコメントid文字列、`create_issue` の `external_id` は
課題キー（例 `PROJ-123`）。pluginが異なるため既存 `jira` のIDと衝突しない
（永続の一意は plugin + event_id + fingerprint）。
actorは実態を保つ（`accountType: app` のみ `bot`、それ以外は `human`。
課題本体イベントは `system`/`unknown`）。個人ユーザーの発言をbotに偽装しない。

## 信頼された接続の扱い

- cloud・principal・actorは `oauth_binding` の検証済み値のみを使う。
  AI・input JSON・envで上書きできない（input schemaに含めない）。
- base URLとpagingの `nextPage` は同cloud境界に閉じる。
  scheme・host・portに加え `/ex/jira/<cloudId>/` 前方一致と `.`/`..`
  除去でcross-host・cross-cloud・path escapeを拒否し、送信前に
  `HostRejected` とする。userinfo付きURLは送らない。
- 同一invoke内は固定世代の1 tokenを使い回す。並行呼出で別ユーザーtokenを混ぜない。
  外部書込を401等で自動replayしない。
- `oauth_binding` / `oauth_credential_provider` 不在・provider不一致・cloud不正は
  外部HTTP前に `CredentialsMissing` とする。接続・世代・refreshの失敗は
  OAuthの型付きエラー（`not_connected` / `binding_mismatch` /
  `refresh_in_progress` / `invalid_grant` 等）をそのまま返し、生のprovider応答・
  秘密・パーサーメッセージを出さない。
- `binding_for` による現在の接続への勝手な取り直しはしない。
  アプリ指定の同じbindingに対してのみ `access_token` を解決する。
  constructorのprovider注入はテスト用の補助であり、暗黙の切替やfallbackではない。
- pure RubyでありRails/DBに直接依存しない。default registryへの登録は
  業務統合（#26）が行う。standaloneテストは新adapterを明示requireし登録する。

## Incomplete polls

検索・各課題のcomments/changelogはそれぞれ最大25ページ。
25ページ目に続きがある、offsetが進まない、全件取得前に空ページになる場合は
`IncompletePoll` を送出し、部分的なevents/cursorは返さず保存済みcursorを保持する。
`*` に分割できないため、上限超過時はそのscopeの取り込みを停止し、
負荷・レート制限を評価したうえで上限変更の検討または永続的な途中再開の実装後に再試行する。
cursorを現在時刻へ進めることや単なる再試行では解消しない。

## 制約・無保証事項

- 同意ユーザーのJiraタイムゾーンを変更させない。JQL日時がユーザータイムゾーンで
  評価される問題は、時間述語を使わず取得後にUTC換算で比較することで回避する。
  既存 `jira` のUTC設定要求とは異なる。
- description/commentはADFのtext・paragraph・list・table・mention・emoji・
  media・cardを簡易抽出する。複雑なマクロやcode blockの書式は失われる。
- `create_issue` はsummary・description・Task固定。必須カスタムフィールドが
  あるプロジェクトでは400になるためJira側で必須項目を外すか別手段を使う。
- scoped host利用のため `url` は `null` になる（`/browse` は返せない）。
- 429は `RateLimited`（`retry_after` 付き）として返す。呼び出し側で待機・再試行すること。
- 投稿成功直後に呼び出し側が停止すると、再試行で重複投稿が起こり得る。
  exactly-onceは保証しない。
- Jira検索はスナップショットではない。5分を超える遅延、権限変更で後から可視に
  なった古いイベント、削除済みイベントの回収は保証しない。
  必要時は以前のcursorから再照合する。
- 全対象課題の子リソースを走査するため、件数に応じてAPI呼出しが増える。

検証は有限HTTP fixtureによる単体テスト。実アカウントの認証・投稿・権限確認は別途必要。

## 公式ドキュメント

- https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/
- https://developer.atlassian.com/cloud/jira/platform/rest/v3/intro/
- https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-search/#api-rest-api-3-search-jql-post
- https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-comments/
- https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/#api-rest-api-3-issue-issueidorkey-changelog-get
- https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/#api-rest-api-3-issue-post
- https://developer.atlassian.com/cloud/jira/platform/apis/document/structure/
