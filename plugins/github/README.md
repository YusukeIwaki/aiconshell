# GitHub プラグイン

GitHub App として動作する in-process プラグイン。resource API の polling で
issue / comment / review / workflow 更新を取得し、コメント返信と issue 作成を行う。
Events API（timeline）一本には依存しない。

## 必要な環境変数

| 変数 | 必須 | 説明 |
| --- | --- | --- |
| `GITHUB_APP_ID` | 必須 | GitHub App ID（数値） |
| `GITHUB_INSTALLATION_ID` | 必須 | 対象 installation の ID（数値） |
| `GITHUB_PRIVATE_KEY` | どちらか必須 | App の PEM 秘密鍵（PEM 本文） |
| `GITHUB_PRIVATE_KEY_FILE` | どちらか必須 | PEM を格納した private ファイルのパス |
| `GITHUB_API_URL` | 任意 | HTTPS API ベース URL。既定 `https://api.github.com`（GHES 用に変更可。userinfo・query・fragment は不可） |

秘密鍵は `GITHUB_PRIVATE_KEY` 直書きか `GITHUB_PRIVATE_KEY_FILE` のどちらかで渡す。
両方ある場合は直書きが優先される。秘密の値はログ・EventLog・catalog に出さない。

## 最小権限（App permissions）

poll のみの場合:

- Issues: Read-only（issues / issue comments の取得に使用）
- Pull requests: Read-only（pull reviews / review comments の取得に使用）
- Actions: Read-only（workflow runs 取得に使用）
- Metadata: Read-only（自動付与）

返信・issue 作成を行う場合、上記に加えて:

- Issues: Read and write
- Pull requests: Read and write（PR へのコメント返信に使用）

`contents` や `administration` は不要。installation token は最長 1 時間で、
アダプターが expiry の 60 秒前に破棄して再取得する。

## 使用エンドポイント

ベースは `GITHUB_API_URL`（既定 `https://api.github.com`）。
`{owner}/{repo}` は `scope` の `owner/repo`。

| 操作 | メソッド・パス |
| --- | --- |
| App JWT → installation token | `POST /app/installations/{installation_id}/access_tokens` |
| latest_events: issues | `GET /repos/{owner}/{repo}/issues?state=all&sort=updated&direction=desc&per_page=25` |
| latest_events: 全 issue コメント | `GET /repos/{owner}/{repo}/issues/comments?sort=updated&direction=desc&per_page=100&since=...` |
| latest_events: 旧 issue 判定 | `GET /repos/{owner}/{repo}/issues/{number}`（親が一覧に無い場合のみ） |
| latest_events: PR reviews | `GET /repos/{owner}/{repo}/pulls/{number}/reviews` |
| latest_events: 全 review comments | `GET /repos/{owner}/{repo}/pulls/comments?sort=updated&direction=desc&per_page=100&since=...` |
| latest_events: workflow runs | `GET /repos/{owner}/{repo}/actions/runs` |
| reply（issue / PR 共通） | `POST /repos/{owner}/{repo}/issues/{number}/comments` |
| create_issue | `POST /repos/{owner}/{repo}/issues` |
| list_issues | `GET /repos/{owner}/{repo}/issues?state=open&sort=created&direction=desc&per_page=30&page=N` |

## 操作

- `latest_events`: issues、リポジトリ単位の issue comments、review comments、
  Actions workflow runs を独立に巡回し、取得した PR の reviews も読む。
  1 回の成功は取得済みページの保存単位であり、リポジトリ全履歴の取得完了を意味しない。
  呼出側は返された全 events を durable ingest してから cursor 全体を保存する。
  途中で HTTP・検証エラーが発生した場合は例外を送出し、部分 cursor を返さない。
- `reply`: `resource_id` は `issue:owner/repo#123` / `pr:owner/repo#123`。
- `create_issue`: `scope` は `owner/repo`。
- `list_issues`（`read_only: true`）: 現在の open issue を 1 ページ分読む
  on-demand 照会。`pull_request` キーを持つ PR は除外する。入力は
  `{"scope": "owner/repo", "cursor": null または {"version":1,"scope":"owner/repo","page":N}}`。
  出力は `{"issues": [...], "complete": bool, "next_cursor": object|null, "truncated": bool, "limit_reached": bool}`。
  各 issue は `id` / `number` / `title` / `body` / `labels` / `state: "open"` / `url` と
  `title_truncated` / `body_truncated` / `labels_truncated` / `url_truncated` の
  明示フラグを持つ。`complete: true` のとき `next_cursor` は null、
  未読ページが残るときは `complete: false` で次ページの cursor を返す。
  ただし上限の 100 ページ目に続きがある場合は `limit_reached: true`、
  `complete: false`、`next_cursor: null` とし、未取得分を完了扱いにしない。
  部分結果が `complete: true` を主張しない。cursor は当該 repository と
  固定クエリに束縛し、token 取得前に検証する。

## list_issues の固定制限

- 1 回の呼び出しで 1 ページ（`per_page=30`）、最大 30 件の正規化 issue。
- 本文 2000、件名 300、ラベル 10 件×各 100、URL 512 バイトで
  打ち切り、対応する `*_truncated` を `true` にする。本文が長い通常の issue も
  全体を読まずに捨てない。URL が制限超えの場合は `url: null` とする。
  バイト数は各フィールドを JSON にエンコードした内容（外側の引用符を除く）で数える。
  日本語・絵文字・エスケープ文字でも UTF-8 の文字境界を維持して切り詰める。
- cursor の `page` は 2〜100。`Link: rel="next"` の origin・path・filter・
  ページ件数が一致し、現在ページの次を指す場合のみ継続ありと判定する。
- worst-case の打ち切り済み出力は `Interaction::QueryService` の
  128,000 バイト予算に収まる。権限は Issues Read-only で足りる。
- `complete` は当該ページの後に続きがないことを示す。各ページは現在の API の
  観測であり、ページ間で issue の作成・クローズが起きると一貫した時点の一覧にはならない。
  結果が partial または truncated の場合、未取得・省略した内容がないとは判断できない。

## Cursor と履歴巡回

初回は cursor を省略するか、`{"since":"2026-09-26T00:00:00Z"}` を渡す。
省略時は全履歴を複数回の poll に分けて取り込む。`since` を指定した場合は
**最初の取得開始日時として固定**し、新しく観測した時刻で上書きしない。
これにより、後のページで見つかった更新を、先に見つかった新しい更新の時刻で除外しない。
返却 cursor は JSON serializable な version 2。以下は巡回途中の例:

```json
{
  "version": 2,
  "scope": "owner/repo",
  "since": null,
  "streams": {
    "issues": {
      "next": "https://api.github.com/repos/owner/repo/issues?state=all&sort=updated&direction=desc&per_page=25&page=3",
      "completed_at": null
    },
    "issue_comments": { "next": null, "completed_at": "2026-09-26T12:00:00Z" },
    "review_comments": { "next": null, "completed_at": "2026-09-26T12:00:00Z" },
    "workflow_runs": {
      "next": "https://api.github.com/repos/owner/repo/actions/runs?per_page=100&page=4",
      "completed_at": null
    }
  }
}
```

各 stream は毎回先頭ページを取得し、残りの予算で `next` から続きを読む。
末尾に達した stream は `next: null` に戻り、次回から再巡回する。
`completed_at` は最後に末尾へ到達した poll の実行時刻。初回巡回中は null、
次の巡回中は前回値を保持する。offset pagination の一貫した snapshot や
「この日時以前の全更新を取得済み」という保証ではない。

| Stream | ページ件数 | 1 poll のページ予算 | 続きの扱い |
| --- | --- | --- | --- |
| issues / PR | 25 | 2（先頭 + 履歴 1） | 最大 50 件を展開、残りは次回 |
| issue comments | 100 | 2（先頭 + 履歴 1） | 最大 200 件、残りは次回 |
| review comments | 100 | 2（先頭 + 履歴 1） | 最大 200 件、残りは次回 |
| workflow runs | 100 | 3（先頭 + 履歴 2） | 最大 300 件、残りは次回 |

300 件を超える run、50 件を超える issue/PR があっても、通常の履歴巡回は成功して進む。
各 stream の進捗は独立し、後方のページを巡回中も先頭は毎回確認する。
古い issue のコメント判定は必要に応じて親を追加取得する。
PR ごとの reviews は別途最大 25 ページまで全取得するため、HTTP 要求総数は
上表の合計より多い（最大 50 PR × 25 review ページ、親判定最大 200 件）。

時刻は timezone を含む ISO8601 と実在日付を厳密検証し、UTC instant で比較・ソートする。
`occurred_at` は UTC ISO8601（`Z`）。固定 `since` から 60 秒前まで overlap して emit し、
下流は `event_id + fingerprint` で重複除去する（親 snapshot は後述の現在値との比較も必要）。
コメント API にはこの下限の `since` を送る。
issue 一覧は下限なしで巡回して PR を発見し、親 issue snapshot は取得後に下限で絞る。
workflow runs は updated-since フィルタが無いため、全履歴を巡回して取得後に下限で絞る。
古い run の再実行を除外しないよう `created` フィルタも使用しない。

PR review は編集時刻を返さず `submitted_at` しか持たないため、観測した PR の
reviews は下限以前のものも emit する。初回巡回では古い review snapshot も取り込まれる。
本文・state の fingerprint で編集を検出するが、`occurred_at` は元の提出日時であり、
emit されたことは新規提出されたことを意味しない。

旧形式の `{"since":...}` は受理し、v2 に移行する。旧 `cursor.next` は拒否する。
必要なら保存済み cursor を元の `since` のみに戻して再巡回する（既存イベントは重複除去）。
v2 の未知キー・異なる scope・不正な stream は拒否する。URL は API origin だけでなく、
対象 repository / endpoint / filter / ページ件数に一致する必要がある。
アダプターが返した cursor を全体のまま保持し、個別 field を手作業で前進させないこと。

payload には issue / comment / review の `body` を含め、
PR 由来は `pr:owner/repo#N`、issue 由来は `issue:owner/repo#N` に正規化して関連付ける。
workflow run は `run:owner/repo/{run_id}`。
親 issue の fingerprint は title / body / state を使い、コメント数・更新日時は使わない。
自分の bot 返信による親の metadata 変更を、元の人間の新規投稿として重複投入しない。
issue の actor は元の作成者であり、最後の編集者を特定する値ではない。
同じ内容へ戻ると同じ semantic fingerprint になる。受信側は親の現在の snapshot と比較し、
連続する同じ値は抑制し、A → B → A の復元（再オープンなど）は別の観測 revision として扱うこと。

## 制約

- 履歴側の更新は、そのページを再訪するまで遅延する。追加・削除・更新で offset が移動すると、
  今回の巡回で飛ばした行を次の巡回で取得する場合がある。固定下限は前進しないが、
  更新量が走査量を上回る状態では全体への到達時間に上限を保証しない。
- REST の現在値を照合する方式であり、取得前に削除されたイベントや、取得間に生じて
  元へ戻った変更は復元できない。監査ログや exactly-once 取得ではない。
- **単一 PR の reviews が 25 ページを超える場合**は `IncompletePoll` で旧 cursor を保持する。
  この個別展開にはまだ再開位置が無く、当該 PR の review paging を再開可能にする実装が必要。
  同じ cursor での再試行や repository scope の変更だけでは履歴量の問題は解消しない。
- installation token 取得・API 呼び出しの 429 / rate limit 残量 0 は
  `RateLimited`（`retry_after` 付き）として返す。呼び出し側で待機・再試行すること。
- `Link: rel="next"` の origin（scheme・host・port）が API origin と異なる場合は
  要求を送らず `HostRejected`。同じ origin でも別 repository / endpoint や異なる filter、
  ページ飛び・逆戻りを拒否する。supplied cursor は token 取得前に検証する。
  API が返す `/repositories/{id}/...` 形式の Link は、同じ endpoint のページ番号だけを採用し、
  設定済みの `/repos/{owner}/{repo}/...` URL に再構築して要求・保存する。
  supplied cursor の数値 repository URL は受理しない。

## 検証

`RBENV_VERSION=3.4.9 rbenv exec bundle exec smartest smartest/plugins` で fake HTTP の
契約テストを実行する。大量履歴の再開、stream ごとの進捗、古い再実行・review 編集、
offset の削除変動、親 metadata による自己返信ループ、cursor の scope/URL 検証を含む。
実アカウントによる認証・API paging・投稿はこの単体テストでは確認しない。

## 公式ドキュメント

- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/about-authentication-with-a-github-app
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-json-web-token-jwt
- https://docs.github.com/en/rest/issues/issues
- https://docs.github.com/en/rest/issues/issues#list-repository-issues
- https://docs.github.com/en/rest/issues/comments
- https://docs.github.com/en/rest/issues/comments#list-issue-comments-for-a-repository
- https://docs.github.com/en/rest/pulls/reviews
- https://docs.github.com/en/rest/pulls/reviews#list-reviews-for-a-pull-request
- https://docs.github.com/en/rest/pulls/comments#list-review-comments-for-a-repository
- https://docs.github.com/en/rest/actions/workflow-runs
- https://docs.github.com/en/rest/using-the-rest-api/using-pagination-in-the-rest-api
- https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
