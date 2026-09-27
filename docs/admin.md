# 管理画面

日本語 server-rendered 管理画面。ERB + 自前 CSS を使う。外部フォント・CDNには依存しない。
AI連携画面は小さなJavaScriptで進行中の更新と入力保護を行う。

- タスクボード (`/admin/tasks`)：状態別ボード、状態フィルタ、50件単位のページ送り
- タスク詳細 (`/admin/tasks/:id`)：概要・作業計画、フィードバック一覧・投稿、実行結果付き履歴、送信アクション
- 層別 AI ポリシー (`/admin/layer_policies`)：provider/model/effort/指示 + 設定診断 + 保存済み設定の接続再確認
- プラグイン (`/admin/plugins`)：対応操作・必要 env 名・設定済み表示（値なし）
- EventLog 検索 (`/admin/event_logs`)：層・種別・タスク・期間・キーワード
- AIアカウント連携 (`/admin/ai_connections`)：provider × worker role の状態確認・連携開始・認証案内・コード入力・キャンセル（[ai-connections.md](ai-connections.md)）
- OAuth連携 (`/admin/oauth_connections`)：Jira・Teamsのユーザー委任OAuth接続の開始・再接続・解除と接続状態の確認（[oauth-connections.md](oauth-connections.md)）。同意後のprovider callbackは公開経路 (`/oauth/:provider/callback`) で受け、queryなし管理画面へ戻す

## 主なファイル

- `config/routes.rb` の `draw(:admin)` 1行 + `config/routes/admin.rb`（詳細定義）。OAuthのprovider callback（`GET /oauth/:provider/callback`、atlassian/microsoft固定）は `config/routes.rb` 直書きの公開経路
- `app/controllers/admin/*.rb`（`BaseController`、各画面、表示アダプタ。OAuthは `OauthConnectionsController` + `OauthStatus`）
- `app/controllers/oauth_callbacks_controller.rb`（公開callback。管理Basic認証なし、session-bound stateが偽造対策）
- `app/controllers/concerns/oauth_browser_session.rb`（CookieStoreの初回nil `session.id` を避ける明示ブラウザ束縛token）
- `app/views/layouts/admin.html.erb`、`app/views/admin/**/*.erb`
- `app/assets/stylesheets/admin.css`
- `app/helpers/admin_helper.rb`
- `smartest/unit/admin_hygiene_test.rb`
- `smartest/integration/admin/*_test.rb` + `support/admin_test_support.rb`
- `docs/admin.md`（本書）

## 依存する公開契約

管理画面は次の実契約に依存する。検証は実モデル・実ライブラリを相手に行う。

- workflow モデル：`Task`（`task_feedbacks` / `task_runs` / `outbound_actions` 関連）、
  `TaskFeedback`（`body/author/author_type/suggested_priority/processed_at`）、
  `TaskRun`（`provider/model/effort/instructions/status/result/error_code/error/...`）、
  `LayerPolicy`（`layer` 一意、provider 必須）、
  `OutboundAction`（`plugin/operation/status/error_code/attempts/...`）。
  フィードバック投稿は人間限定（`author_type` を `"human"` に固定）で
  `TaskFeedback` 行の作成のみ行い、タスク状態・優先度・run への直接更新はしない。
  送信アクションは状態・エラーコードの表示のみで、再送操作は持たない。
- AI表示：`Admin::AiStatus.providers` は常に claude/codex/muse。
  `diagnosis(provider, layer:)` はworkerが保存した `AiConnection` のrole別snapshotを読む。
  WebローカルのCLIや認証ホームから推測しない。snapshotなしは未確認、読取失敗は診断不可。
  ログイン・状態確認の運用入口は [ai-connections.md](ai-connections.md) を参照。
- plugins ポート：`Aiconshell::Plugins::Registry.default.catalog`
 （`id/operations/required_env/configured`、env は名前のみ）。失敗時は行内通知に縮退する。
- EventLog ポート：`EventLogging::Search.search`（実体は `Aiconshell::Observability.search`）。
  未設定・障害時は行内ステータスに縮退し、500 にしない。
- foundation：`ADMIN_USERNAME` / `ADMIN_PASSWORD` の運用設定（未設定は fail closed）。

表示アダプタ（`Admin::AiStatus` / `Admin::PluginStatus` / `Admin::EventLogSearch`）は
上記への委譲とテスト用注入点のみを持ち、業務判断は一切行わない。

## ふるまい要点

- タスクボードは `status` に既知の状態を指定して絞り込み、`page` で50件ずつ表示する。
  並び順は優先度・更新日時・IDの降順で固定し、同順位でもページ境界を安定させる。
  前後のページリンクは状態フィルタを保持し、フィルタ送信時は先頭ページへ戻る。
  未知・配列・オブジェクトの状態は全状態に戻し、ページは1〜9桁の正の整数文字列のみ
  受け付ける。不正なページは1、最終ページを超える有効値は最終ページに正規化する。
  件数ゼロでも1ページ目として表示する。最大200件の打ち切りは行わない。
- タスク詳細は `Task.work_plan` と各実行結果の文字列 `outcome` / `summary` を
  改行を保って escape 表示する。結果全体の JSON、prompt、stdout、instructions は表示せず、
  結果がない場合やフィールドの型が不正な場合も安全に表示する。
- 全 `/admin` に Basic 認証。SHA256 ダイジェストの `secure_compare`、未設定時は全拒否。
  CSRF は Rails 既定のまま（無効化しない）。OAuthの開始・解除も Basic + 実CSRF検証の POST のみ。
  provider callback（`/oauth/:provider/callback`）だけは Basic 認証なしの公開 GET とする
  （providerは認証情報を送れない）。偽造対策は `Oauth::AuthService` のブラウザsession束縛・
  TTL・一回消費の state で行い、callback入力は短い文字列のみ受け付ける（配列/Hash/過大値は拒否）。
- provider は claude/codex/muse を常に選択・保存可。未設定は診断バッジのみで保存成功し、
  未知 ID は 422 で拒否する。業務workerを直接実行するボタンは持たない。
  AI連携の運用操作は別の永続受付と専用auth queueを使い、Task/TaskRunを変更しない。
- 一覧の保存済み行には「接続状態を再確認」があり、保存済み provider と層対応 role の
  状態確認を `AiAuth::RequestService#request_status` に依頼する。対象は保存済み設定からのみ
  決まり、リクエストの付加パラメータで変更できない。受付は `admin_ai_connections_path` へ
  遷移し、接続済みとは表示しない。進行と結果は AIアカウント連携画面で確認する。
  未設定行は「設定が必要です」と案内し、受け付けない。無効なポリシーでも確認できる。
  保存済みポリシーや業務タスクは変更しない。不明な層・未認証・CSRF不正では実行しない。
- 検索パラメータは層 allowlist・bounded text・数値 task_id・厳密な時刻 parse・上限 clamp。
  空の task_id・期間は `nil` に正規化して ClickHouseAdapter に渡す（文字列のまま渡さない）。
  sort/order パラメータは受け付けない。
- 未信頼の本文・イベント・カタログ文言はすべて ERB 既定で escape して表示する。
  秘密値・資格情報は画面・エラーに出さない。
- OAuth連携画面は `Oauth::AuthService`（`begin` / `callback` / `disconnect` /
  `public_status`）だけを使い、Task/TaskRun/業務jobを作らない。provider固定callback・
  session-bound state・TTL・一回消費を維持し、code/state/token/verifierを画面・ログ・
  例外・EventLog・Refererに出さない。認可リダイレクトは `redirect_to` を使わず手動
  Location + `no-referrer` で送る（`Redirected to` ログへの認可URL漏洩防止）。
  callback後はqueryなし画面へ戻し、全応答に `Cache-Control: no-store` を付ける
  （画面は `Referrer-Policy: same-origin`、認可・callbackのリダイレクトは `no-referrer`）。
  未設定・未接続・接続中・接続済み・再認証必要・失敗を別のバッジで区別し、
  「設定済み」（env完備）と「接続済み」（検証済み接続）を混同しない表示にする。
  検証済みprincipal表示名/ID・cloud/tenant・付与scopeを表示し、secretの値は表示しない。
  解除はアプリ内利用停止・token破棄でありprovider側同意取り消しは別である旨を明示する。
  個人PAT入力UI・PAT fallbackは持たない。Bot運用（service account/Bot名義）と
  OAuth2代理運用（同意ユーザー名義）の区別は画面とplugin READMEに記す。

タスク画面の PostgreSQL 回帰テストは、205件の全ページ到達、状態フィルタの維持、
不正パラメータ、結果・作業計画のXSSエスケープ、未許可の結果フィールド非表示を含む。
