# ユーザー委任OAuth接続（Jira / Teams の同意ユーザー基盤）

Atlassian（Jira Cloud 3LO）と Microsoft（Entra Authorization Code + PKCE S256、
confidential client）で「同意したユーザーとして」動くための共通基盤（#22）。
既存の `jira`（service account）と `teams`（Graph application + Bot）は維持し、
委任版 `jira_oauth` / `teams_oauth` プラグインは後続 Issue（#24 / #25）がこの
基盤の上に作る。管理画面（#23）と業務フロー統合（#26）も後続である。

初版の範囲は 1 利用環境あたり provider（`atlassian` / `microsoft`）ごとに
接続ユーザー 1 名。Jira Cloud は運用設定で指定した 1 cloud ID、Microsoft は
指定した 1 Entra tenant（work / school account）に固定する。Confluence、
複数接続の選択、SSO によるアプリログインは対象外である。

運用用 OAuth 接続は Task / TaskRun と独立し、Interaction / Coordination /
Execution の責務は変えない。既存 AI CLI 認証モデル（subscription ログイン）を
流用しない。

## 公開 Ruby ポート

pure Ruby の入口は `lib/aiconshell/oauth.rb`（`Aiconshell::Oauth`）。
Rails の運用サービスは `Oauth::AuthService` / `Oauth::TokenService` /
`Oauth::CredentialProvider`、永続モデルは `OauthConnection` /
`OauthAuthAttempt` である。`lib/aiconshell` は Zeitwerk 管理外であり、
各ファイルが明示 `require` する（`docs/architecture.md` の Ruby ポート契約）。

```ruby
require "aiconshell/oauth"

config = Aiconshell::Oauth::Config.new(env: ENV)
config.atlassian.configured?           # true/false（変数名のみ、値は出さない）
config.missing_env_names("microsoft")  # ["OAUTH_MICROSOFT_CLIENT_ID", ...]

Aiconshell::Oauth::Atlassian.authorize_url(config: config, state: raw_state)
Aiconshell::Oauth::Microsoft.authorize_url(config: config, state: raw_state, challenge: challenge)
Aiconshell::Oauth::Atlassian.exchange_code(transport:, config:, code:, redirect_uri:)
Aiconshell::Oauth::Microsoft.exchange_code(transport:, config:, code:, redirect_uri:, verifier:)
Aiconshell::Oauth::Atlassian.refresh(transport:, config:, refresh_token:)
Aiconshell::Oauth::Microsoft.refresh(transport:, config:, refresh_token:)
Aiconshell::Oauth::Atlassian.verify_connection(transport:, config:, access_token:)
Aiconshell::Oauth::Microsoft.verify_connection(transport:, config:, access_token:, granted_scope:)
```

Rails 側の公開契約は次のとおり。`transport` / `clock` / `secret_store` /
`event_sink` はすべて注入可能であり、テストは実サービスに境界フィクスチャを
差し込む（`docs/testing.md`）。

```ruby
auth = Oauth::AuthService.new(env: ENV, transport: transport, clock: Time,
                              secret_store: Oauth::SecretStore.default,
                              event_sink: WorkflowEvents)
begun = auth.begin(provider: "microsoft", browser_session_id: session.id)
# { "attempt_id", "authorize_url", "state", "expires_at" }
connection = auth.callback(provider: "microsoft", state: params[:state],
                           code: params[:code], browser_session_id: session.id,
                           error: params[:error])
auth.disconnect(provider: "atlassian")
auth.public_status(provider: "microsoft") # 秘密なし（未設定は unknown）

creds = Oauth::CredentialProvider.new(env: ENV, transport: transport, clock: Time,
                                      secret_store: Oauth::SecretStore.default,
                                      event_sink: WorkflowEvents)
binding = creds.binding_for("atlassian") # 秘密なし（Aiconshell::Oauth::Binding）
token = creds.access_token(binding.to_h) # 直前の外部書込のためだけに解決する
```

失敗は型付き例外が安全な分類コード（`#code`）だけを持ち、生の provider 応答・
秘密・パーサーメッセージは message / log / EventLog に出さない。
`Aiconshell::Oauth::ErrorCodes.sanitize` が未知値を `provider_error` に畳む。

## 暗号化と秘密の扱い

- access token・refresh token・PKCE verifier は共有 `SECRET_KEY_BASE` から
  専用 salt（`aiconshell oauth v1`）で導出した鍵で認証付き暗号化
  （AES-256-GCM、JSON）し、PostgreSQL には ciphertext のみ置く。
  AI 接続の challenge 領域とは鍵が別である。
- `OauthConnection` / `OauthAuthAttempt` は `inspect` と `serializable_hash`
  から ciphertext・平文・state・verifier を除外する。token を plugin 入力・
  AI 入出力・EventLog data・例外 message に入れない。
- authorization code は交換時以外保持しない（DB に書かない）。
- DB 制約: `oauth_connections.provider` 一意、`oauth_auth_attempts.state_digest`
  一意、`refresh_lease_token` 一意。

## provider 設定と env

| 用途 | Atlassian（Jira Cloud 3LO） | Microsoft（Entra + PKCE） |
| --- | --- | --- |
| client | `OAUTH_ATLASSIAN_CLIENT_ID` / `OAUTH_ATLASSIAN_CLIENT_SECRET`（または `..._SECRET_FILE`） | `OAUTH_MICROSOFT_CLIENT_ID` / `OAUTH_MICROSOFT_CLIENT_SECRET`（または `..._SECRET_FILE`） |
| 固定先 | `OAUTH_ATLASSIAN_CLOUD_ID`（1 cloud ID） | `OAUTH_MICROSOFT_TENANT_ID`（1 Entra tenant） |
| redirect | `OAUTH_ATLASSIAN_REDIRECT_URI`（固定・https） | `OAUTH_MICROSOFT_REDIRECT_URI`（固定・https） |
| 固定 endpoint | `https://auth.atlassian.com/...`、`https://api.atlassian.com/...` | `https://login.microsoftonline.com/{tenant}/...`、`https://graph.microsoft.com/...` |
| 要求 scope | `offline_access` `read:jira-work` `write:jira-work` `read:jira-user` | `offline_access` `User.Read` `ChannelMessage.Read.All` `ChannelMessage.Send` `Chat.Read` `ChatMessage.Send` |

- 既存 service account 用の `JIRA_*` / `TEAMS_*` とは独立した変数であり、
  混在・転用しない。callback 入力で token URL / redirect / tenant を選べない。
- redirect URI は https 固定（明示設定の loopback http のみ可）、userinfo・
  fragment を拒否する。redirect 追従はしない（認可ヘッダの別 origin 漏洩防止）。
- 未設定の provider は `configured?` / `public_status` が安全に未設定表示し、
  `binding_for` は `NotConnected`（`unconfigured`）で拒否する。既存 registry・
  旧 plugin・AI 接続・業務フローに影響しない。この基盤だけでは旧 default
  registry へ委任 plugin を登録しない。

## 認証試行と state

- `begin` は 32 byte の高エントロピー state を発行し、SHA256 digest だけを
  `oauth_auth_attempts` に保存する。生 state は authorize URL 用に一度だけ
  返し、DB に書かない。試行はブラウザ session digest に結び付け、
  provider・固定 redirect URI・試行 TTL（600 秒）を検証する。固定
  client ID・redirect URI・cloud ID・tenant ID・要求 scope の snapshot も
  試行に保存し、開始後の設定変更はその試行を完了させない。
- callback は state 検証→一回消費（`consumed`）→開始時 snapshot と現在設定
  の照合→世代 fencing→固定設定での交換→検証の順に進み、ネットワーク中に
  DB transaction / row lock を保持しない。二重 callback は 2 回目を
  `state_mismatch` で拒否し、再接続・解除後の古い callback は世代 fencing
  で `expired` として拒否する。交換・検証の後、公開直前に試行の状態
  （`consumed` のみ可）・TTL・世代・設定 snapshot を再確認し、接続保存と
  試行成功を同じ transaction で行う（片方だけ成功させない）。
- `state` 不一致・期限切れ・同意拒否（`error=access_denied`）は試行だけを
  終端し、元の正常接続を壊さない。初回接続行がない間の callback 中に
  `disconnect` しても、試行の終端状態を再確認するため接続は復活しない。
- Microsoft のみ PKCE S256 を使う（verifier は試行に暗号化保存し交換で消費）。
  Atlassian 3LO に PKCE は送らない（仕様にない対応を捏造しない）。
- Atlassian は `audience=api.atlassian.com`、`prompt=consent`、
  `offline_access` を付けて認可し、accessible-resources で指定 cloud ID と
  Jira 権限（`read:jira-work` / `write:jira-work` / `read:jira-user`）を検証
  する。`offline_access` は token 付与フラグであり API 権限ではないため、
  accessible-resources の scope 充足には要求しない。同じ cloud の `/myself`
  で `accountId`（非空文字列）・表示名を確定し、数値/Hash を `to_s` で正常
  データに変換しない。
- Microsoft は固定 tenant の token endpoint で交換し、Graph `/me` で外部
  principal（`id`、非空文字列）を確定する。未検証 JWT の claim は信頼根拠に
  しない。tenant は `common` / `organizations` / `consumers` を受け付けず、
  固定 tenant のみ。token 応答の `scope` は access token の API 権限であり、
  省略時は仕様どおり「要求した scope」とみなして受理し、明示された不足
  のみ `scope_mismatch` とする。`offline_access` の文字列含有を成功条件に
  しない（refresh token 発行と区別する）。
- provider 応答は JSON shape・必須 scope・正の有効期限・空 token を検証し、
  数値/Hash の scope・principal を正常化せず `unexpected_response` 等で
  拒否する。timeout・429・`invalid_grant`（Atlassian は 400/401 に加え
  3LO 資料どおり 403 も失効扱い）・保存前 crash を分類し、生の応答 body
  や `error_description` は公開しない（共有 HTTP 層は body を保持しない
  ため OAuth 専用の status 分類境界で判定する）。失効
  （`invalid_grant`）は `needs_reauth`（再接続が必要）として分かる。

## token の再利用と refresh

- 有効な token は再利用し、期限 120 秒前から refresh する。refresh token の
  rotation は 1 write で原子的に保存し、同時 refresh は排他 lease
  （120 秒）+ fencing で制御する。lease 取得→ネットワーク→確定の 3 段階で、
  途中の再接続・解除・lease 期限切れは古い結果を破棄し、新しい接続や解除を
  復活させない。`refresh_token` 欠落・復号失敗の `needs_reauth` 更新と、
  期限切れ lease の clear は commit してから例外を上げる（transaction 内
  raise による rollback を防ぎ、実 DB reload で確認する）。
- refresh 応答で scope が明示的に縮小した場合や、接続時から client /
  tenant / cloud 設定が変わった場合は、元の検証済み binding に正常 token
  として払い出さない（省略時は仕様どおり要求 scope とみなす）。lease は
  clear し、古い接続を上書きしない。
- rotation がサーバーで受理された後の timeout / DB 保存失敗 / プロセス停止
  では旧 refresh token の有効性を断言できない。この場合は旧行を残して
  安全に再試行し（次回 refresh が可否を証明する）、明示の `invalid_grant`
  でのみ `needs_reauth` とする。結果不明の処理が新規接続を上書きしない。

## 世代（generation）の意味

- `oauth_connections.generation` は「どの接続か」の版数である。初回成功・
  置き換え成功と解除で +1 し、単なる refresh では変えない。初回も世代を
  進めるため、並行した 2 件目の遅延 callback は fencing で `expired` となる。
- 後続 plugin に渡すのは秘密を含まない binding
  （接続 ID / 世代 / provider / principal / tenant / cloud）であり、同じ
  binding に対してだけ token を取得できる。不一致は外部書込前に
  `binding_mismatch` で拒否する。`binding_for` の戻り値（`Binding`）は
  そのまま `access_token(binding)` に渡せる（`from_h` は `Binding` を
  そのまま受け付ける）。

## 秘密の非露出

- `ProviderConfig`（固定設定）・`SecretBox` / `SecretStore`（暗号鍵）・
  `AuthService` / `TokenService` / `CredentialProvider` の `inspect` / `to_s`
  は値を出さない。`OauthConnection` / `OauthAuthAttempt` と `Binding` も
  従来どおり ciphertext・平文・state・verifier を `inspect` /
  `serializable_hash` から除外する。

## 解除の意味

- `disconnect` はローカル token と active な試行を消去して再利用不可にし、
  世代を進める。プロバイダー側の同意取消しとは区別する（provider 側で
  取り消された場合は refresh 失敗として `needs_reauth` になる）。

## UI / adapter / 業務統合の依存契約（後続 Issue 向け）

- 管理画面（#23）は `Oauth::AuthService`（`begin` / `callback` / `disconnect` /
  `public_status`）だけを使い、Task / TaskRun / 業務 job を作らない。
  provider 固定 callback・session-bound state・TTL・一回消費を維持し、
  code / state / token / verifier を画面・ログ・例外・EventLog・Referer に
  出さない。
- 委任 adapter（#24 / #25）は `Oauth::CredentialProvider` から binding を受け、
  外部書込の直前に `access_token(binding)` で解決する。binding をユーザー・
  AI が指定できないこと、cloud / tenant / principal を上書きできないこと、
  `Bearer` 先が検証済み固定 origin に閉じることを各 adapter が保証する。
- 業務統合（#26）は接続 ID・世代・principal・tenant / cloud の snapshot を
  信頼されたアプリ側で固定し、解除・置換と処理の競合を fencing で扱う。
  この基盤の `default registry` への登録は #26 が行う。

公式仕様:

- <https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/>
- <https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-auth-code-flow>
- <https://learn.microsoft.com/en-us/graph/api/user-get?view=graph-rest-1.0>
