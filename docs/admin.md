# 管理画面

日本語 server-rendered 管理画面。ERB + 自前 CSS を使う。外部フォント・CDNには依存しない。
AI連携画面は小さなJavaScriptで進行中の更新と入力保護を行う。

- タスクボード (`/admin/tasks`)：状態別ボード、状態フィルタ、50件単位のページ送り
- タスク詳細 (`/admin/tasks/:id`)：概要・作業計画、フィードバック一覧・投稿、実行結果付き履歴、送信アクション
- 層別 AI ポリシー (`/admin/layer_policies`)：provider/model/effort/指示 + 設定診断 + 保存済み設定の接続再確認
- アカウント (`/admin/accounts`)：GitHub Apps / Discord アカウントの設定・接続確認、管理APIキーの発行・再発行（値の表示は発行直後の1回のみ）
- EventLog 検索 (`/admin/event_logs`)：層・種別・タスク・期間・キーワード
- AIアカウント連携 (`/admin/ai_connections`)：provider × worker role の状態確認・連携開始・認証案内・コード入力・キャンセル（[ai-connections.md](ai-connections.md)）

## 主なファイル

- `config/routes.rb` の `draw(:admin)` 1行 + `config/routes/admin.rb`（詳細定義）
- `app/controllers/admin/*.rb`（`BaseController`、各画面、表示アダプタ。アカウントは `AccountsController`）
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
- アカウント：`GithubAppsAccount` / `DiscordAccount`（singleton 行。認証情報は
  暗号化保存）と各 `has_one` のヘルスチェック状態
  （`GithubAppsHealthCheckState` / `DiscordHealthCheckState`。`updated_at` が
  最終確認日時で `created_at` は持たない）。
  接続確認は `Accounts::HealthCheck` が plugin の `health_check` 操作で行う。
- 管理APIキー：`AdminApiToken`（singleton 行。SHA256 ダイジェストのみ保存）。
  `rotate!` が新規発行し、平文は戻り値でのみ返る（再表示なし）。
- AI表示：`Admin::AiStatus.providers` は常に claude/codex/muse。
  `diagnosis(provider, layer:)` はworkerが保存した `AiConnection` のrole別snapshotを読む。
  WebローカルのCLIや認証ホームから推測しない。snapshotなしは未確認、読取失敗は診断不可。
  ログイン・状態確認の運用入口は [ai-connections.md](ai-connections.md) を参照。
- EventLog ポート：`EventLogging::Search.search`（実体は `Aiconshell::Observability.search`）。
  未設定・障害時は行内ステータスに縮退し、500 にしない。
- foundation：`ADMIN_USERNAME` / `ADMIN_PASSWORD` の運用設定（未設定は fail closed）。

表示アダプタ（`Admin::AiStatus` / `Admin::EventLogSearch`）は
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
  CSRF は Rails 既定のまま（無効化しない）。アカウントの保存・接続確認・キー再発行も
  Basic + 実CSRF検証の POST/PATCH のみ。
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
- アカウント画面は Task/TaskRun/業務jobを作らない。GitHub Apps の秘密鍵は `.pem`
  ファイルのアップロードでのみ受け付け、RSA 秘密鍵として読めることを保存前に検証する。
  秘密鍵・Bot トークンの値は画面・ログ・例外・EventLog に出さず、GitHub の公開鍵指紋
  （非秘密）のみ表示する。接続確認は疎通に加え、GitHub では必要権限の有無も確認し、
  結果はヘルスチェック状態（`updated_at` が最終確認日時）に保存する。
- 管理APIキーの平文は発行・再発行の直後に1回だけ表示し、再表示・再取得はできない。
  再発行すると古いキーは即座に無効になる。一覧表示は先頭数文字と更新日時のみ。

タスク画面の PostgreSQL 回帰テストは、205件の全ページ到達、状態フィルタの維持、
不正パラメータ、結果・作業計画のXSSエスケープ、未許可の結果フィールド非表示を含む。
