# AIアカウント連携（管理画面）

`/admin/ai_connections` から Claude / Codex / Muse Code のサブスクリプションログイン開始、認証URL/コード案内、Claudeの認証コード送信、キャンセル、worker別の接続状態確認を行う。control と execution は別の永続volumeのため、provider × worker role の6組を別々にログインする。

## なぜworker別にログインが必要か

- control と execution は別々の認証ホーム（Composeはrole別の名前付きvolume、Railwayはサービス別の `/data`）と別々のトークン更新を持つ。一方へのログインで他方は使えない。
- 層とworkerの対応: 対話層・整理層は control、実行層は execution。各層のAIポリシーで選んだ provider に対応する worker へログインする。
- 未連携の provider も層ポリシーで選択・保存できる。不足は実行時に分類済みエラーになる（APIキー課金への切替はしない）。

## 使い方

1. 管理画面の「AI連携」を開く。各 provider × role に状態（未確認/未連携/準備不足/失敗/接続済み）と確認時刻が出る。直近の終了結果（失敗・取消・期限切れ）も残り、再試行できる。
2. 「状態確認」で worker が公式CLIを使って subscription まで確かめる。バイナリやホームの存在だけでは接続済みにしない。層別AIポリシー一覧の保存済み行にある「接続状態を再確認」も同じ状態確認を依頼する（保存済み provider と層対応 role を使用し、受付を接続済みと表示しない）。
3. 「連携開始」でログインを開始する。認証URLとユーザーコード（ある場合）が表示される。ブラウザで開いて承認する。URLのリンク文言は短いラベルのみで、秘密クエリ全文は表示しない。
4. Claude のようにコード入力が必要な手順では、表示された入力欄にコードを入れて送信する。Claudeは authorizationCode#state 全体を1行で入力し、#以降を取り除かない。送信されたコードは暗号化して一時保存され、workerへ一度だけ渡した後に削除される。受付後は「受付済み」表示になり、二重送信は拒否される。
5. device 承認の手順ではコード入力なしで待つ。進行中は5秒ごとに自動更新される。コードの入力中・入力済みは入力保護のため自動更新を延期し、未入力・非フォーカスなら自動更新される。送信後は自動更新を再開する。「更新する」リンクでも手動更新できる。「キャンセル」はいつでも押せる。待機中（queued）の取消は即時確定して再開始できる。処理中・入力待ちの取消は即時反映され、古い処理が完了後に上書きしない。
6. ログインの期限は15分。期限切れ・キャンセル・失敗では秘密（URL/コード）はDBから削除される。workerは書込直前に取消・期限・所有権を再検証し、期限切れ・取消済みの結果で接続状態を上書きしない。

## worker・queue・volume

### アプリケーション内の入口

Webの運用操作は `AiAuth::RequestService` に渡す。主な公開メソッドは
`request_login(provider:, worker_role:)`、`request_status(provider:, worker_role:)`、
`submit_code(session_uuid:, code:)`、`cancel(session_uuid:)`。
`request_status` は `AiAuthSession` を永続化して role別の `AiAuthJob` を予約し、
同じ provider/role に進行中の操作があればそのsessionを返す。
戻り値は受付・進行中の操作であり、接続済みの判定ではない。
層ポリシー一覧の「接続状態を再確認」は保存済み `LayerPolicy` の provider と
`Admin::AiStatus.worker_role_for(layer)` の role で `request_status` を呼ぶ。
リクエストに provider などを付け足しても保存済み設定と異なる対象へ変更できない。
未設定の層は受け付けず、保存済みポリシーや業務 `Task` / `TaskRun` は変更しない。
`AiAuth::WorkerService` が実行して `AiConnection` snapshot を更新する。
これらの操作は業務 `Task` / `TaskRun` や `LayerPolicy` を変更しない。

画面用の `Admin::AiStatus.diagnosis(provider, layer:)` はsnapshotを読む。
層→role対応は `Admin::AiStatus.worker_role_for(layer)` を使用する。
`AiConnection` がない/未確認でもprovider選択と状態確認の受付は可能。
provider/roleは既知値のみ許可し、認証やCSRFを迂回する経路を追加しない。

### 実行プロセス

- worker には `AICONSHELL_WORKER_ROLE=control|execution` を明示する。Web には付けない。auth job は要求 role と一致しない worker では実行せず、安全な分類で失敗する。
- 専用queue `ai_auth_control` / `ai_auth_execution` を、対応 worker の別1スレッドpoolで処理する。長い認証待ちが通常の control/execution 処理を塞がない。
- Compose: `config/queue_control.yml` と `config/queue_execution.yml` が2pool構成。`ruby bin/check-compose` が検証する。
- 認証ホームは worker の private volume のみ（controlは `claude_auth` / `codex_auth` / `muse_auth`、executionはそれぞれ `execution_` を付けたvolume、Railwayは各 worker の `/data/auth/*`）。Web に CLI・認証volume・worker role を付けない。長期トークンは worker volume だけに置く。
- 短期の認証秘密（認証URL/ユーザーコード/入力コード）は共有PostgreSQLに `SECRET_KEY_BASE` 由来の専用キーで暗号化（AES-256-GCM・JSON）して保存し、完了・失敗・キャンセル・期限で削除する。

旧Composeからの更新では既存の認証volumeをcontrolに維持する。executionは新しい専用volumeになるため、管理画面から再ログインする。既存volumeの削除や認証ファイルのコピーは行わない。

## Railway

- control / execution サービスに `AICONSHELL_WORKER_ROLE` をそれぞれ `control` / `execution` で設定する。Web には設定しない。
- 各 worker に別々の `/data` volume を1個ずつ付け、`/data/auth/*` と `/data/workspaces` を使う。volume の初期化と所有者設定は [deployment.md](deployment.md) の手順どおり。
- `RUNTIME_TARGET=ai` のまま使い、ログインは管理画面から行う（コンテナに入っての手動ログインも同じ volume に保存される）。

## 失敗時の見方

- 未確認: まだ worker で確かめていない。状態確認から始める。
- 未連携: worker で未ログインを確認した。連携開始からログインする。
- 準備不足: CLI や認証場所が worker にない。イメージと volume を確認する。
- 失敗: 直近の確認・ログインが失敗した。画面の日本語メッセージに従って再試行する。スナップショットがない場合も終了セッションの安全な分類を表示する。
- 進行中のまま期限が来たら期限切れとして回復し、再操作できる。古い job が新しい結果を上書きしない（claim fencing + last_session_id）。

## EventLog

- 層は固定語彙のみ: Web由来の要求・取消受付・期限回復は `interaction`、workerの運用結果は role 別に `control→coordination` / `execution→execution`。
- `auth.requested` / `auth.cancel_requested` / `auth.cancelled` / `auth.expired` / `auth.succeeded` / `auth.failed` を出し、data は provider/role/operation/status のみ。URL・コード・stdout/stderr・生例外は出さない。
- 層ポリシー画面の状態表示は同じ worker スナップショットを読み、最終確認時刻と役割を表示する。Webローカル診断は使わない。
