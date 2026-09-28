# GitHub Issueから実装・検収する

Issue URLだけを新しい実装セッションに渡せるよう、恒久的な前提は
[AGENTS.md](../AGENTS.md) → [実装skill](../.agents/skills/aiconshell-issue/SKILL.md) →
[設計資料の入口](development.md) から参照する。
Issueには今回の変更理由、観測できる期待動作、対象外、依存Issueを記す。
[Issueテンプレート](../.github/ISSUE_TEMPLATE/implementation.md) を使える。
実装方針を逐一Issueへ複製する必要はない。
この手順をIssueだけで引き継いだ [Muse実装試行の記録](issue-workflow-verification.md) も参照できる。

各フェーズの手順は `.agents/skills/` のskillにある（一覧は [AGENTS.md](../AGENTS.md#skills-by-phase)）。
要件の整理 `aiconshell-requirements`、現状調査 `aiconshell-investigation`、
タスク化 `aiconshell-issue-planning`、優先度管理 `aiconshell-prioritization`、
設計・実装 `aiconshell-issue`、テスト `aiconshell-testing`、検収 `aiconshell-review`。
skillは手順のチェックリストで、正となる手順・契約は本書と各設計資料に置く。

## 準備する人（コーディネーター）

実装と動作確認は原則Muse Codeに委譲し、コーディネーターが独立して検収する。
実装用worktreeを指定されたセッションは実装担当であり、再委譲は不要。
Museが使えないなどの制約があれば、その制約を報告し、同じIssueの範囲で引き継ぐ。

1. `gh issue list` で重複を確認し、1つの変更を1 Issueにする。
   独立する変更は別Issueにし、依存するものは必要なbase commit/Issueを明示する。
2. mainの状態と既存worktreeの使用状況を確認する。受け入れ済みでcleanなworktreeを
   再利用できる。`codex/issue-N-description` ブランチを合意したbaseから用意する。
   同じファイル・public interfaceを変える並列レーンは先に担当を決める。
3. `gh` がIssueを読めること、RubyとBundler、Dockerまたは隔離済みテストDBを確認する。
   実装者へproduction環境変数や個人の認証キャッシュを渡さない。

指定済みのworktreeのルートで、例えば次を実行する（`N`を実際のIssue番号へ置換）。

```sh
muse exec --yolo --no-foreign-personal-context --no-session-log \
  --model muse-spark-1.3-contributor --reasoning-effort xhigh \
  'GitHub Issue https://github.com/YusukeIwaki/aiconshell/issues/N を実装してください。'
```

これは実装用Museの起動例であり、アプリのLayerPolicy既定値を変更する指示ではない。
`--yolo` はこの開発手順で明示的に許可された実装セッション用。
CLIの対応オプションは更新時に `muse exec --help` で確認する。
skillは `.agents/skills/` に置く。Museでの検出確認は
`muse skills list --source project --trust-workspace --json` を使う。
AGENTS.mdから直接辿れるので、自動skill選択に依存しない。

## 実装する人

1. Issue本文と追記、AGENTS.md、該当領域の設計・コード・既存回帰を読む。
   Issueが指定しない契約は維持する。要件衝突は具体的に示し、無関係な作業は続けられる。
2. 指定されたworktree内で実装し、境界だけを差し替えるテストを追加・修正する。
   [testing.md](testing.md) の手順で、既存経路と今回の失敗条件を検証する。
   不要なリファクタリングや未依頼の運用設定変更は含めない。
3. 変更したpublic contractの正の資料を更新し、diffに秘密・runtime log・無関係な差分が
   ないことを確認してlocal commitする。PR作成、push、main merge、Issue closeは行わない。
4. 次の形式で検収へ引き渡す。コーディネーターへの最終応答でよく、投稿権限を追加で意味しない。

<a id="handoff"></a>
## Handoff

- Issue番号、branch、commit。
- 利用者に見える変更と、維持・変更した境界（短く）。
- 実際に実行したコマンド、成功/失敗/skip。CI・本番・実アカウント確認は区別する。
- 未解決の懸念、未実行の理由、移行・設定が必要ならその内容。

## 検収する人（コーディネーター）

実装者の報告だけで合格にせず、Issueの期待動作、責務の境界、失敗時の副作用、
追加テストが実物を検証しているかをdiffから確認する。適切な検証を自分でも実行する。
不足はIssueに具体的な再現条件/期待動作を追記し、同じIssueの実装レーンに戻す。
設計の発見性に問題があれば正の資料や入口を修正し、個別の長大なプロンプトで補わない。

検収後、cleanなmainに戻り最新origin/mainを取り込む。baseが変わったら競合解消と
影響範囲の再確認を行ってから以下を実行する。実装者には実行させない。

```sh
git merge --no-ff codex/issue-N-description -m 'Describe the accepted change; closes #N'
git push origin main
```

PRは作らない。pushされたmerge commitでIssueが閉じることとCIを確認する。
main pushはRailwayの自動デプロイを起動するので、コード変更なら反映結果も確認する。
デプロイ・実アカウント確認を行っていない場合は完了報告に明記する。

## 実装セッションが止まったとき

同じworktreeで同時に書き込む2つ目のセッションを起動しない。
自分が起動したプロセスの終了と差分を確認し、残った作業を保持してから再開する。
繰り返すCLI障害をコードの失敗と混同しない。試行回数と未検証点を引き渡しに残す。
モデルの生transcriptや認証値はコミット/Issueへ貼らず、検証結果だけを要約する。
