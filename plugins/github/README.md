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
| `GITHUB_API_URL` | 任意 | API ベース URL。既定 `https://api.github.com`（GHES 用に変更可） |

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
| latest_events: issues | `GET /repos/{owner}/{repo}/issues?state=all&sort=updated&since=...` |
| latest_events: 全 issue コメント | `GET /repos/{owner}/{repo}/issues/comments?sort=updated&since=...` |
| latest_events: 旧 issue 判定 | `GET /repos/{owner}/{repo}/issues/{number}`（親が一覧に無い場合のみ） |
| latest_events: PR reviews | `GET /repos/{owner}/{repo}/pulls/{number}/reviews` |
| latest_events: 全 review comments | `GET /repos/{owner}/{repo}/pulls/comments?sort=updated&since=...` |
| latest_events: workflow runs | `GET /repos/{owner}/{repo}/actions/runs` |
| reply（issue / PR 共通） | `POST /repos/{owner}/{repo}/issues/{number}/comments` |
| create_issue | `POST /repos/{owner}/{repo}/issues` |

## 操作

- `latest_events`: issues（一覧 `since` 付き）→ リポジトリ単位の issue comments、
  PR ごとの reviews、リポジトリ単位の review comments、Actions workflow runs を取得する。
  issue コメントと review コメントはリポジトリ単位で独立に poll するため、
  古い issue/PR への新規・編集コメントも欠落しない。
  全ページ取得の途中で失敗したら例外を送出し、cursor は前進させない。
- `reply`: `resource_id` は `issue:owner/repo#123` / `pr:owner/repo#123`。
- `create_issue`: `scope` は `owner/repo`。

cursor は `{"since": "ISO8601 UTC"}`（JSON serializable）。
`since` は ISO8601 厳密検証、未知キーは拒否する。
`cursor.next` に前回中断 URL を渡すと issues 一覧だけそこから再開するが、
host は API origin のみ許可する（legacy 互換）。

時刻はすべて UTC instant として比較・ソートし、`occurred_at` は UTC ISO8601（`Z`）で正規化する。
文字列の辞書順比較はしない。`since` クエリは watermark から 60 秒の overlap を引いて送り、
取得した overlap 帯も含めて `occurred_at >= query_since` を emit する
（同一時刻・遅延 index 対策の at-least-once。下流で event_id + fingerprint により重複除去する）。
payload には issue / comment / review の `body` を含め、
PR 由来は `pr:owner/repo#N`、issue 由来は `issue:owner/repo#N` に正規化して関連付ける。
workflow run は `run:owner/repo/{run_id}`。

## 制約

- 1 回の poll で取得する issue は最大 50 件、1 エンドポイントのページ追跡は最大 25
  （workflow runs は最大 3 ページ）。上限到達時は件数を黙って切り捨てず、
  `IncompletePoll` を送出して cursor を前進させない。呼び出し側は旧 cursor を保持し、
  scope を絞るか backlog を消化してから再試行すること。
- Actions runs 一覧に `since` パラメータは無く、取得後に時刻で絞り込む。
- installation token 取得・API 呼び出しの 429 / rate limit 残量 0 は
  `RateLimited`（`retry_after` 付き）として返す。呼び出し側で待機・再試行すること。
- `Link: rel="next"` の origin（scheme・host・port）が API origin と異なる場合は
  要求を送らず `HostRejected`。

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
- https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
