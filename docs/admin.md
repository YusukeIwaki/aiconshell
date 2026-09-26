# 管理画面 (Issue #7)

日本語 server-rendered 管理画面。ERB + 自前 CSS のみ（外部フォント・CDN・JS 不使用）。

- タスクボード (`/admin/tasks`)：状態別ボード
- タスク詳細 (`/admin/tasks/:id`)：概要、フィードバック一覧・投稿、実行履歴
- 層別 AI ポリシー (`/admin/layer_policies`)：provider/model/effort/指示 + 設定診断
- プラグイン (`/admin/plugins`)：対応操作・必要 env 名・設定済み表示（値なし）
- EventLog 検索 (`/admin/event_logs`)：層・種別・タスク・期間・キーワード

## 所有ファイル（このレーン）

- `config/routes/admin.rb`（`draw(:admin)` で読み込む。`config/routes.rb` 自体は触らない）
- `app/controllers/admin/*.rb`（`BaseController` + 5 画面 + 3 表示アダプタ）
- `app/views/layouts/admin.html.erb`、`app/views/admin/**/*.erb`
- `app/assets/stylesheets/admin.css`
- `app/helpers/admin_helper.rb`
- `smartest/unit/admin_hygiene_test.rb`
- `smartest/integration/admin/*_test.rb` + `support/admin_test_support.rb`
- `docs/admin.md`（本書）

## 統合に必要な他レーンの公開契約

管理画面は次の契約だけに依存する。いずれも `docs/architecture.md` の通り。

- Issue #6（workflow）：`Task`（`title/description/status/priority/source_plugin/source_resource_id/next_action_at`、
  `feedbacks` / `runs` 関連）、`TaskFeedback`（`task/body/author/processed_at`）、
  `TaskRun`（`provider/model/effort/instructions/status/lease_token/lease_expires_at/result/error/started_at/finished_at`）、
  `LayerPolicy`（`layer` 一意、`provider/model/effort/instructions/enabled`）。
  フィードバックは `TaskFeedback` 行の作成のみで行い、タスク状態・優先度・run への直接更新はしない。
- Issue #4（AI）：`Aiconshell::Ai::Registry.default` の `providers`（常に claude/codex/muse）、
  `configured?(provider)`、`diagnose(provider)`。未ロード時は「診断不可」表示に縮退する。
- Issue #3（plugins）：`Aiconshell::Plugins::Registry.default.catalog`
 （`id/operations/required_env/configured`、env は名前のみ）。未ロード・失敗時は行内通知に縮退する。
- Issue #5（EventLog）：`EventLogging::Search.search`（なければ `Aiconshell::Observability.search`）。
  未設定・障害時は行内ステータスに縮退し、500 にしない。
- Issue #2（foundation）：`config/routes.rb` の `draw` ブロック内に `draw(:admin)` の1行追加、
  `ADMIN_USERNAME` / `ADMIN_PASSWORD` の運用設定（未設定は fail closed）。

表示アダプタ（`Admin::AiStatus` / `Admin::PluginStatus` / `Admin::EventLogSearch`）は
上記への委譲とテスト用注入点のみを持ち、業務判断は一切行わない。

## ふるまい要点

- 全 `/admin` に Basic 認証。SHA256 ダイジェストの `secure_compare`、未設定時は全拒否。
  CSRF は Rails 既定のまま（無効化しない）。
- provider は claude/codex/muse を常に選択・保存可。未設定は診断バッジのみで保存成功し、
  未知 ID は 422 で拒否する。worker 直接実行ボタンは持たない。
- 検索パラメータは層 allowlist・ bounded text・数値 task_id・厳密な時刻 parse・上限 clamp。
  sort/order パラメータは受け付けない。
- 未信頼の本文・イベント・カタログ文言はすべて ERB 既定で escape して表示する。
  秘密値・資格情報は画面・エラーに出さない。
