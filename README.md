# agents-kit — 複数AIセッション並行開発キット

1つの Git リポジトリに対し、別々のターミナルで動く複数の AI（Claude Code / Codex 混在可）が、あなたの随時指示を受けながら**コンフリクトを起こさず並行実装**するための調整キットです。

仕組みは git だけで完結します（AI 固有機能に依存しない）。調整情報は origin 上の専用ブランチ `agent-state` に記録され、main へのマージは直列化された `agents merge` コマンドだけが行います。main への直接 push はローカルフックが物理的に拒否します。

## 導入（リポジトリごとに1回）

```
./install.sh /path/to/your-repo
```

これで対象リポジトリに以下が入ります。

- `.agents/bin/agents` — 調整 CLI（python3 標準ライブラリのみ）
- `.agents/PROTOCOL.md` — AI が読んで従う規約
- `.agents/config.json` — このクローン専用の設定（コミットされない）
- `AGENTS.md` / `CLAUDE.md` — AI への案内ブロック（既存ファイルには追記）
- pre-push フック — main / agent-state への直接 push を拒否
- origin に `agent-state` ブランチと、main に `.agents` 一式（自動 push）

導入後に1つだけ手作業: `.agents/config.json` の `test_cmd` にテストコマンドを書いてください（例 `"pytest -q"`。テストが無いリポジトリは `"true"` と明示）。これを書くまで done / merge は動きません。書いたら repo ルートで一度 `sh -c '<test_cmd>'` を実行し、**main の時点で素で通る**ことを確認してください（通らない test_cmd は全セッションの done / merge を止めます）。言語の生成物（`__pycache__` 等）は repo の `.gitignore` に入れておいてください（worktree に残ると done が停止します）。

導入クローンの checkout は install.sh が自動で main 最新に追いつかせます（追跡ファイルに未コミット変更がある場合などは案内だけ出して触りません）。

## 日常の使い方

複数ターミナルでそれぞれ Claude Code / Codex を開き、**各セッションに最初にこう言うだけ**です。

> .agents/PROTOCOL.md を読んで従って。

あとは普通に指示してください（「ログイン画面作って」「あ、やっぱりボタンは赤で」）。AI 側がプロトコルに従い、

1. あなたの指示原文を `agents directive` で台帳に記録し、
2. `agents start` で担当を宣言して専用 worktree を作り、
3. 実装して `agents done`（rebase → 全テスト → push）、
4. `agents merge` で直列マージ（マージ結果ごとに全テスト）

という流れを自動で回します。担当の重複・指示の矛盾（後の指示が勝ち）・マージ順は AI 同士がスクリプト経由で調整します。

あなたが状況を見たいときは、リポジトリ内でそのまま:

```
.agents/bin/agents sync     # 最新を取得して全体表示（担当・指示・ロック・警告）
.agents/bin/agents status   # オフライン表示のみ
```

## config.json の設定

`.agents/config.json`（クローンローカル。コミットされません。別クローンでは install.sh を再実行して再設定）:

| キー | 既定値 | 意味 |
|---|---|---|
| `test_cmd` | null | **必須設定**。worktree ルートで `sh -c` 実行される全テスト。無しなら `"true"` |
| `build_cmd` | null | テスト前に走らせるビルド（任意） |
| `remote` | `"origin"` | 調整に使う remote |
| `main_branch` | 検出値 | install.sh が既定ブランチを自動検出して書き込む |
| `state_branch` | `"agent-state"` | 調整用ブランチ名 |
| `worktree_root` | `".worktrees"` | worktree の置き場（repo 内） |
| `claim_ttl_hours` | 24 | 担当宣言の生存時間（切れると evict 可能に） |
| `merge_lock_ttl_min` | 30 | merge ロックの生存時間。**フルテスト所要時間の2倍以上に** |
| `pr` | `"auto"` | gh がある GitHub repo でのみ done が PR を作る。`"off"` で無効 |

変更は次の `agents sync` から全セッションに即時に効きます。

## トラブル時の見方

- **完全な監査ログ**: `git log --oneline --stat refs/remotes/origin/agent-state`。誰がいつ何を宣言・マージ・解除したかが全部残っています。任意時点の中身は `git show <sha>:claims/xxx.json`。
- **AI が「push を拒否された」と言う**: 正常です。main へは `agents merge` だけが入れられます。AI が回避策（`--no-verify` 等）を口にしたら禁止と伝えてください。
- **担当が残ったまま AI が死んだ**: どのセッションでも `agents evict --dry-run` で確認 → `agents evict`。worktree とブランチは消されず残るので、未 push の作業を確認してから片付けます。
- **merge ロックが残った**: `agents sync` で STALE 表示が出ていれば `agents evict --lock-only`。出ていなければ誰かのテストが走っているだけなので待ちます。
- **exit code 8 を見た**: そのセッションの担当が失効した合図。AI は作業を止めて `.agents/PROTOCOL.md` のプレイブックに従います。
- **`.worktrees/` にゴミが溜まった**: `agents sync` が「孤児」として列挙します。中身（未 push 作業）を確認してから `git worktree remove` してください。
- GitHub を使う場合の推奨設定: main と agent-state に対し branch protection で「force push 禁止」「削除禁止」の2つだけを有効化。**Require a pull request 系は設定しない**（merge の直接 push と非互換）。

## 開発リポジトリ構成（このディレクトリ）

- `kit/agents` / `kit/PROTOCOL.md` — 配布物本体
- `install.sh` — 導入スクリプト（冪等。再実行で kit を更新配布）
- `tests/smoke.sh` / `tests/breaker.sh` — ローカル bare origin を使った自動検証（`bash tests/smoke.sh && bash tests/breaker.sh`）
- `SPEC.md` / `BRIEF.md` — 仕様と設計入力
