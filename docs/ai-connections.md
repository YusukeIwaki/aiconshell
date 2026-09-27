# AIアカウント連携（管理画面）

`/admin/ai_connections` から Claude / Codex / Muse Code のサブスクリプションログイン開始、認証URL/コード案内、Claudeの認証コード送信、キャンセル、接続状態確認を行う。対話層・整理層・実行層の全てが共通の execution worker を使うため、provider ごとの3組だけを管理する。1回の provider ログインを全3層で使う。

## なぜ1回のログインで足りるか

- execution worker だけが AI CLI を実行し、認証ホーム（Composeは execution 用の名前付きvolume、Railwayは execution サービスの `/data`）とトークン更新を持つ。全層のAI実行と接続確認はこの worker に対応する。
- 層とworkerの対応: 対話層・整理層・実行層はいずれも execution。各層のAIポリシーで選んだ provider へのログインは1回で足りる。
- 未連携の provider も層ポリシーで選択・保存できる。不足は実行時に分類済みエラーになる（APIキー課金への切替はしない）。

## 使い方

1. 管理画面の「AI連携」を開く。各 provider に状態（未確認/未連携/準備不足/失敗/接続済み）と確認時刻が出る。直近の終了結果（失敗・取消・期限切れ）も残り、再試行できる。
2. 「状態確認」で worker が公式CLIを使って subscription まで確かめる。バイナリやホームの存在だけでは接続済みにしない。層別AIポリシー一覧の保存済み行にある「接続状態を再確認」も同じ状態確認を依頼する（保存済み provider に対して execution の確認を行い、受付を接続済みと表示しない）。
3. 「連携開始」でログインを開始する。認証URLとユーザーコード（ある場合）が表示される。ブラウザで開いて承認する。URLのリンク文言は短いラベルのみで、秘密クエリ全文は表示しない。
4. Claude のようにコード入力が必要な手順では、表示された入力欄にコードを入れて送信する。Claudeは authorizationCode#state 全体を1行で入力し、#以降を取り除かない。送信されたコードは暗号化して一時保存され、workerへ一度だけ渡した後に削除される。受付後は「受付済み」表示になり、二重送信は拒否される。
5. device 承認の手順ではコード入力なしで待つ。進行中は5秒ごとに自動更新される。コードの入力中・入力済みは入力保護のため自動更新を延期し、未入力・非フォーカスなら自動更新される。送信後は自動更新を再開する。「更新する」リンクでも手動更新できる。「キャンセル」はいつでも押せる。待機中（queued）の取消は即時確定して再開始できる。処理中・入力待ちの取消は即時反映され、古い処理が完了後に上書きしない。
6. ログインの期限は15分。期限切れ・キャンセル・失敗では秘密（URL/コード）はDBから削除される。workerは書込直前に取消・期限・所有権を再検証し、期限切れ・取消済みの結果で接続状態を上書きしない。

## worker・queue・volume

### アプリケーション内の入口

Webの運用操作は `AiAuth::RequestService` に渡す。主な公開メソッドは
`request_login(provider:, worker_role:)`、`request_status(provider:, worker_role:)`、
`submit_code(session_uuid:, code:)`、`cancel(session_uuid:)`。
`worker_role` は `execution` のみ受け付ける。`control` を含む未知値は
`InvalidRequest` として拒否し、行も job も作らない。
`request_status` は `AiAuthSession` を永続化して `ai_auth_execution` へ `AiAuthJob` を予約し、
同じ provider に進行中の操作があればそのsessionを返す。
戻り値は受付・進行中の操作であり、接続済みの判定ではない。
層ポリシー一覧の「接続状態を再確認」は保存済み `LayerPolicy` の provider に対して
`request_status(provider:, worker_role: "execution")` を呼ぶ。
リクエストに provider などを付け足しても保存済み設定と異なる対象へ変更できない。
未設定の層は受け付けず、保存済みポリシーや業務 `Task` / `TaskRun` は変更しない。
`AiAuth::WorkerService` が execution worker 上で実行して `AiConnection` snapshot を更新する。
これらの操作は業務 `Task` / `TaskRun` や `LayerPolicy` を変更しない。

画面用の `Admin::AiStatus.diagnosis(provider, layer:)` は execution snapshot を読む。
層→role対応は `Admin::AiStatus.worker_role_for(layer)` を使用する（全層が `execution` を返す）。
`AiConnection` がない/未確認でもprovider選択と状態確認の受付は可能。
provider/roleは既知値のみ許可し、認証やCSRFを迂回する経路を追加しない。

### 実行プロセス

- worker には `AICONSHELL_WORKER_ROLE=execution` を明示する。Web には付けない。auth job は execution の worker でのみ実行し、それ以外では安全な分類で失敗する。旧 control 向けの要求は worker に届く前に拒否される。
- 専用queue `ai_auth_execution` を、execution worker の別1スレッドpoolで処理する。長い認証待ちが通常の execution 処理を塞がない。
- Compose: `config/queue_execution.yml` が2pool構成。`ruby bin/check-compose` が検証する。`config/queue_control.yml` に残る `ai_auth_control` pool は切替後に使われない。コンテナ・queue設定の整理は別Issueの担当であり、ここでは変えない。
- 認証ホームは execution worker の private volume のみ（Composeは `execution_claude_auth` / `execution_codex_auth` / `execution_muse_auth`、Railwayは execution worker の `/data/auth/*`）。Web に CLI・認証volume・worker role を付けない。長期トークンは worker volume だけに置く。
- 短期の認証秘密（認証URL/ユーザーコード/入力コード）は共有PostgreSQLに `SECRET_KEY_BASE` 由来の専用キーで暗号化（AES-256-GCM・JSON）して保存し、完了・失敗・キャンセル・期限で削除する。

旧2worker構成からの更新では execution 側の既存認証volume・snapshot・session を正とする。旧 control の `connected` 状態を execution にコピーしてはならない。旧 control の履歴行はDBに残してよいが、現行の接続としては表示しない。既存volumeの削除や認証ファイルのコピーは行わない。

## 切替手順（旧 control worker の停止と安全な失効）

旧 control 向けに実行中だった認証（queued / running / waiting）と、旧 `ai_auth_control` queue に残った job は、次の順序で失効させる。

1. 旧 control worker を停止する。これ以降、旧 worker が結果を書き込むことはない。
2. `bin/rails ai_auth:revoke_legacy_control` を実行する（`AiAuth::RequestService#revoke_legacy_control!`）。
   実行中だった旧 control session を取消（期限切れは期限切れ）として確定し、秘密を消去する。期限切れ・取消済みの結果で接続状態を上書きしない。以後は冪等に何もしない。
3. 同じ入口が `AiAuthJob` かつ queue `ai_auth_control` の job だけを破棄する（関連する実行行を含む）。業務 `Task` / `TaskRun`、`LayerPolicy`、通常の control queue の job、execution 側の session/job には触れない。

制約:

- 切替前に旧 control worker を停止すること。停止せずに失効させた場合でも、遅れて届いた旧処理の書込は claim fencing で拒否される（終端行への上書きはしない）が、正規の手順ではない。
- 新規の control 宛て認証は受付・実行の両方で拒否される。旧 queue に job が届くことはない。
- 認証cacheのコピーやvolume削除はこの手順では行わない。コンテナ・queue設定の変更も別Issueの担当である。

## Railway

- execution サービスに `AICONSHELL_WORKER_ROLE` を `execution` で設定する。Web には設定しない。
- execution worker に `/data` volume を付け、`/data/auth/*` と `/data/workspaces` を使う。volume の初期化と所有者設定は [deployment.md](deployment.md) の手順どおり。
- `RUNTIME_TARGET=ai` のまま使い、ログインは管理画面から行う（コンテナに入っての手動ログインも同じ volume に保存される）。

## 失敗時の見方

- 未確認: まだ worker で確かめていない。状態確認から始める。
- 未連携: worker で未ログインを確認した。連携開始からログインする。
- 準備不足: CLI や認証場所が worker にない。イメージと volume を確認する。
- 失敗: 直近の確認・ログインが失敗した。画面の日本語メッセージに従って再試行する。スナップショットがない場合も終了セッションの安全な分類を表示する。
- 進行中のまま期限が来たら期限切れとして回復し、再操作できる。古い job が新しい結果を上書きしない（claim fencing + last_session_id）。

## EventLog

- 層は固定語彙のみ: Web由来の要求・取消受付・期限回復・切替失効は `interaction`、execution worker の運用結果は `execution`。
- `auth.requested` / `auth.cancel_requested` / `auth.cancelled` / `auth.expired` / `auth.succeeded` / `auth.failed` を出し、data は provider/role/operation/status のみ。URL・コード・stdout/stderr・生例外は出さない。
- 層ポリシー画面の状態表示は同じ execution スナップショットを読み、最終確認時刻と役割を表示する。Webローカル診断は使わない。
