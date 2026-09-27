# Issueだけを入口にする実装試行

2026-09-27、[整備Issue #18](https://github.com/YusukeIwaki/aiconshell/issues/18) と
[実装Issue #19](https://github.com/YusukeIwaki/aiconshell/issues/19) で確認した記録。
これは当日の実測であり、全Issueの自動成功を保証するものではない。
通常の進め方は [Issue開発手順](issue-development.md) を参照。

## 試行条件

- Muse Code 1.4.0（1.4.0-R4302.1）、`muse-spark-1.3-contributor`、effort `xhigh`。
- Issue専用の `codex/issue-19-policy-connection-check` と別worktree。
- 各回を新規 `muse exec --yolo --no-foreign-personal-context --no-session-log` で開始。
  個人ルール、以前の会話、前セッションのresumeを入力にせず、依頼本文は毎回この1行のみ。

```text
GitHub Issue https://github.com/YusukeIwaki/aiconshell/issues/19 を実装してください。
```

課題は「AIポリシー一覧から保存済み設定の接続状態を再確認する」。
WebにCLIがないこと、層とworker roleが一対一でないこと、認証操作が業務Taskとは別であることを
理解する必要がある。Issueは利用者が観測する期待動作を示し、実装先のserviceやqueue名は
リポジトリの設計資料から辿れる構成にした。

## 初回と資料の修正

初回baseは `1aa4853`。実行記録からIssue取得、`aiconshell-issue` skillの読み込み、
設計の入口・AI連携・開発手順・testing・architecture・adminの参照を確認した。
WebのCLI起動や業務Taskの作成を加えず、既存RequestServiceとrole対応を再利用した。
実装者は別のPostgreSQL/ClickHouseを用意し、12件の新規回帰を含めた検証後に
`b17b091` をlocal commitし、テスト用containerを停止した。PR・push・merge・closeは行っていない。

資料を調べ、試行を観察して次を修正した。

- 古いadminの「WebでCLIを診断する」説明を削除し、worker snapshotと運用操作の契約に揃えた。
  provider資料も、workerでのログインを管理画面から開始する説明へ接続した。
- テスト環境調査で他プロジェクトのcontainer環境変数まで参照したため、空きport確認と
  自分のテストサービスの接続情報だけを使う手順を明記した。実際のテストは専用DBを使用した。
- 初回の対象テストは1件失敗後に実装者自身が修正したが、`tail` へのpipeが終了コードを
  隠していた。`pipefail`とSmartestの失敗・skip件数確認を手順に加えた。
- 検収で、ページ全体の同じ文言を探すだけでは別の表示によって誤って通ることを確認した。
  対象の行・form・通知要素を特定するアサーションをテストガイドに加えた。

検収者の別DBで `bin/test all` は722件成功したが、追加の再現テストで未設定行の列ずれと
queued login直後の誤った受付メッセージを検出した。
再現条件と期待動作を [Issueコメント](https://github.com/YusukeIwaki/aiconshell/issues/19#issuecomment-5853582872) に記載した。
資料の修正base `6a6b365` を取り込んだ `7d6bad0` から、同じ1行だけで新しいMuseセッションを開始した。

## 最終検収

再試行は更新済みskill・設計入口・開発手順・テストガイドとIssueコメントを参照し、
`4c393f9` をlocal commitした。追加の指示文や前セッションの会話は渡していない。
通知要素を対象にした進行中login/連打の回帰、未設定行のセル配置、TaskRun不作成、
保存済みポリシー属性の不変を確認するテストへ修正した。
テスト中の失敗を検出して自力で修正し、今度は `pipefail` 付きで失敗を保持した。
他レーンのDBを使わず、自分のテストcontainerだけを停止した。

検収者は別のPostgreSQL・ClickHouseで以下を実行した。

| 検証 | 結果 |
| --- | --- |
| `RBENV_VERSION=3.4.9 rbenv exec bundle exec ./bin/test all` | unit 89 + plugins 124 + ai 152 + integration 357 = 722件成功、失敗・skipなし |
| 独立した追加の再現テスト（セル幅・通知要素） | 修正前は2件失敗、修正後は2件成功 |
| `RBENV_VERSION=3.4.9 rbenv exec ruby bin/rails zeitwerk:check` | 成功 |
| `muse skills list --source project --trust-workspace --json` / `muse skills validate` | project skillとして検出、共通Agent Skills形式の検証成功 |
| skill-creatorの `quick_validate.py` / 資料の相対リンク / `git diff --check` | 成功 |

アプリの実アカウントログインやAI推論、GitHub/Teamsへのテスト投稿は行っていない。
ローカルDBを使う結合試験と、外部アカウントの実行試験は別である。
実装者によるPR・push・main merge・Issue closeはなく、最終検収と取り込みは
コーディネーターが担当した。生transcriptや一時HTMLはリポジトリへ保存していない。
