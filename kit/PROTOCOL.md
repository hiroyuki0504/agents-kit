# PROTOCOL — 複数AIセッション並行開発の協調プロトコル（agents-kit v1）

この文書は AI セッションが読んで従う規約である。全ルールは命令形で書く。読み終えるまで作業を始めるな。

## 1. 最初にすること

1. `.agents/bin/agents sync` を実行せよ。
2. この文書を最後まで読め。
3. ◆「ユーザーから指示の発言を受けたら、その発言があったターンの内に `agents directive "<発言の原文>"` で記録せよ。実装・調査・返答のどれよりも先に行え」

## 2. 鉄則（5 条）

1. ◆「main へ直接 push するな。マージは `agents merge` だけが行う（フックが拒否する。拒否されたらそれは停止命令であり、回避ではなく merge コマンドに戻れ）」
2. ◆「作業は必ず `agents start` が作った自分の worktree の中で行え。主 checkout と他人の worktree に書き込むな」
3. ◆「ユーザーの指示は要約せず原文のまま `agents directive` で台帳に記録してから動け」
4. ◆「done と merge の前に必ず sync し、`!! NEW` の directive を読め。矛盾したら後の指示（seq が大きい方）が正」
5. ◆「`gh pr merge`・GitHub Web UI のマージボタン・積み PR（agent ブランチを base にした PR）は禁止」

## 3. 正常系フロー（1 本道）

以下の順で実行せよ。各コマンドはリポジトリ内ならどこでも `.agents/bin/agents` で起動できる（worktree 内で見つからない時はリポジトリルートの `.agents/bin/agents` を絶対パスで実行せよ）。

1. 状況確認:

   ```
   .agents/bin/agents sync
   ```

   期待出力: `main:` / `lock:` / `claims:` / `directives:` の一覧と警告。

2. ユーザー指示を記録（発言のあったターンの内に。原文のまま）:

   ```
   .agents/bin/agents directive "ログイン画面を作って" --scope "ログイン画面"
   ```

   期待出力: 1 行目に `d00043` の形式の番号。

3. 担当を宣言し worktree を得る:

   ```
   .agents/bin/agents start login-ui --directive d00043 --paths "src/auth/**,tests/auth/**" --intent "ログイン画面の実装"
   ```

   期待出力: worktree の絶対パス・branch・base_sha。表示された他 claim の intent/interfaces を読み、意味の衝突が無いか判断せよ。

4. 表示された worktree に `cd` して実装せよ。コミットは小さく分けよ。30 分ごと目安に worktree 内で `agents sync` を実行せよ（claim の延命は worktree 内での sync だけが行う）。

5. 完成したら worktree 内で:

   ```
   .agents/bin/agents done
   ```

   done は rebase → 全テスト → branch push → PR 作成（gh がある GitHub repo のみ）を行う。テストが失敗したら push されない。直して再実行せよ。

6. main へ反映:

   ```
   .agents/bin/agents merge login-ui
   ```

   merge はロック取得 → クリーン worktree でマージ → シンボル消失チェック → 全テスト → main push → 反映確認 → 後片付けを行う。

## 4. 異常系プレイブック（症状で引け）

- **agents コマンドが『CAS 敗北』『リトライ上限』と言った**: 正常。自動リトライ済み。exit 5 なら少し待って再実行。
- **git push が『直接 push は禁止』『停止命令』と言った**: それはあなたへの停止命令。main へは `.agents/bin/agents merge <slug>` だけ。`--no-verify` や環境変数での回避は禁止。
- **.agents/bin/agents が見つからない**: リポジトリルートの `.agents/bin/agents` を絶対パスで実行せよ。
- **start が claim 衝突と言った**: 相手の intent を読み、待つ / 分担変更 / slug 変更を選ぶ。奪うな。
- **新 directive が自分の作業と矛盾**: 小さな方向転換なら claim を保ったまま新 directive に従って作り直し、`done --seen` で復唱。根本から覆ったら `agents release` → 新 `start`。矛盾したまま merge するな。
- **merge ロックが残っている**: sync で stale 表示なら `agents evict --dry-run` で確認してから `agents evict --lock-only`。stale でないなら待て。
- **『ロックが奪取されていた / 奪取した』警告**: 手動修復不要。安全は main push の FF 検査が守る。テストが長い repo なら config の `merge_lock_ttl_min` をテスト所要の 2 倍以上に上げよ。
- **rebase コンフリクト**: worktree 内で解消 → `git add` → `git rebase --continue` → 再度 `agents done`。
- **テスト失敗**: push されていない。直してから再度 done / merge。
- **done の branch push が失敗した**: そのまま再度 `agents done`（push 前に fetch するので自己回復する）。繰り返すなら stderr をユーザーに報告。
- **自分の claim が evict されていた（exit 8）**: 作業を止めよ。sync → 生きている directive を確認 → 新しく start からやり直し、旧 branch から必要分を取り込む。旧 claim の slug が別セッションに再claim されていても、その claim・worktree・branch に触るな。
- **start が途中で死んだ（claim はあるが worktree が無い）**: 自分のターミナルの事故だと確認できた場合のみ `agents release <slug> --force`。worktree が残っていれば中身を確認してから `git worktree remove`。確信が無ければユーザーに報告。
- **worktree に agents.json が無い**: `git rev-parse --absolute-git-dir` 直下に `{"slug":...,"agent":...,"branch":...}` を手書きで復元してよい（agent と slug は branch 名 `agent/<agent>/<slug>` から逆引きできる）。
- **merge が途中で死んだ**: もう一度 `agents merge <slug>` を実行すれば安全（push 済みなら回収経路が後片付けだけを行う）。残った `.worktrees/merge-*` は中身を確認し、ユーザーに報告してから消す。
- **worktree が汚れていると言われた**: `git status` で確認。他セッションの残骸なら触らず報告。
- **長時間の離席から戻った**: 作業再開の前にまず worktree 内で `agents sync`。自分の claim が生きているか確認してから続きをせよ。

## 5. 後勝ちルール

- 矛盾の定義: 同じ対象への両立しない指示。
- seq が大きい directive が常に正（`agent-state` のコミット順＝全順序。時刻は使わない）。
- 作業途中で負けた側は議論せず巻き戻す。
- 判断に迷う組は両方の directive 番号を挙げてユーザーに 1 行で確認せよ（確認結果も directive として記録せよ）。

## 6. 禁止事項

- `gh pr merge`。
- GitHub Web UI のマージボタン。
- 積み PR（agent ブランチを base にした PR）。
- main・agent-state への直接 push と force push。
- `git push --no-verify`。
- フックが検査する環境変数を手で設定する行為（install.sh と agents の内部のみ例外）。
- 他人の worktree・claim の操作（`release --force` は所有者が死んだと確信できる時のみ）。
- `--seen` の偽装（実際に読んでから復唱せよ）。
- ユーザーの明示承認なしの `--allow-lost-symbols`。
- agent-state ブランチの手動編集・手動 push。

## 7. コマンドリファレンス

| コマンド | 要約 |
|---|---|
| `agents directive "<原文>" [--scope "<1行>"] [--supersedes d12,d15]` | ユーザー指示の原文を台帳に記録（どこで実行してもよい） |
| `agents start <slug> --directive dNN --paths "<g1,g2>" --intent "<1行>" [--interfaces "<a,b>"]` | claim（CAS）+ origin/main SHA 固定 worktree + branch 作成 |
| `agents sync [--all] [--json]` | fetch + 状態表示 + claim 延命（worktree 内のみ延命） |
| `agents status [--json]` | 表示のみ（fetch なし・オフライン可） |
| `agents done [--seen dNN]` | rebase → 全テスト → branch push → PR（任意） |
| `agents merge [<slug>] [--seen dNN]` | 直列化された唯一の main 反映経路 |
| `agents release [<slug>] [--force]` | claim の自発的解放（branch と worktree は残る） |
| `agents evict [--dry-run] [--lock-only]` | TTL 切れ claim / lock の掃除 |

終了コード:

| code | 意味 |
|---|---|
| 0 | 成功 |
| 2 | 引数・使い方の誤り |
| 3 | 前提不成立（config 不足、claim worktree 外、dirty、未 ack directive、install 未実行） |
| 4 | 競合（slug 使用中、パス重複、merge ロック保持中、マージコンフリクト） |
| 5 | リトライ上限（CAS 10 回 / merge 再走 2 回） |
| 6 | 外部コマンド失敗（git 致命エラー、build/test 失敗、worktree 作成失敗、state 巻き戻り検知） |
| 7 | 検証失敗（クリーン worktree 検査、シンボル消失、origin/main 反映確認） |
| 8 | **claim 喪失 = 作業停止シグナル**。作業を止めてプレイブック「claim が evict されていた」へ |

## 8. 付録

### デバッグ手段

- `git log --oneline --stat refs/remotes/origin/agent-state` が完全な監査ログ。
- `git show <sha>:claims/<slug>.json` で任意時点の状態を読める。
- コミットメッセージ（`directive d00043` / `claim` / `ready` / `seen` / `lock merge` / `merge-log` / `release` / `evict`）だけで流れが読める。

### GitHub branch protection 推奨設定（正確に）

main と agent-state に対して有効化するのは **force push 禁止（Allow force pushes をオフ）** と **ブランチ削除禁止（Allow deletions をオフ）** の 2 つだけ。**Require a pull request before merging 系は設定しない**（`agents merge` の直接 push と非互換でツールが自壊する。どうしても設定する場合はユーザー自身を bypass に入れる）。

### 孤児の掃除

- `agents sync` の孤児 worktree 一覧を確認せよ。
- 残存 agent ブランチは `git ls-remote origin 'refs/heads/agent/*'` で確認せよ。
- どちらも、中身（未 push の作業）を確認し、ユーザーに報告してから消せ。

### 複数クローン運用時の注意

- クローンごとに `install.sh` を実行せよ（フックはクローンローカル）。
- `.agents/config.json` はクローンローカル（コミットされない）。クローンごとに `test_cmd` を設定せよ。
- 他クローンの claim は `(worktree不在)` と表示されるが、それだけでは死んだ証拠にならない。evict は TTL のみで判断される。

### config.json

- `test_cmd` の変更は次の `agents sync` から全セッションに即時に効く（ルートのファイルを読むため）。
- `merge_lock_ttl_min` はフルテスト所要時間の 2 倍以上に設定せよ（ハートビートがあるため下回っても安全性は壊れないが、警告が増える）。
- クロックスキュー数分は無害（時刻は TTL の鮮度判定と表示にのみ使い、順序判定には使わない）。
