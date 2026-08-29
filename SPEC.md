# SPEC: agents-kit v1 — マルチAIセッション協調キット 実装仕様（最終版）

作成: 2026-08-30。入力は BRIEF.md。初稿に対する敵対レビュー3系統（並行性・アトミック性 / AI追従性・運用エルゴノミクス / 障害・復旧・エッジケース）の裁定を反映した最終版。本書だけを読めば追加判断ゼロで実装できることを目標とする。
実装物は `install.sh`、`.agents/bin/agents`（python3 単一ファイル、標準ライブラリのみ）、`.agents/PROTOCOL.md` の3つ。

---

## R. レビュー裁定記録

指摘IDは 並A*（並行性）/ 運B*（エルゴノミクス）/ 復C*（障害復旧）。重複指摘は1行に統合。裁定はすべて本文に反映済み。裁定にあたり hooksPath による pre-push 無効化と、同時 push 敗者の stderr `! [remote rejected] ... (incorrect old value provided)`（git 2.53.0）を本セッションでも再実測し、両レビューの実測主張を追認した。

### blocker

| ID | 指摘（要約） | 裁定 |
|---|---|---|
| 並A1 | CAS本命レースの stderr `[remote rejected] (incorrect old value)` 等を致命扱いし成功基準1を自ら落とす | **採用**。CAS敗北パターンに4種追加（§5.3、WRITE-STATE と merge 手順9の両方）。exit 5 で stderr 全文表示 |
| 並A2/復C1 | claim 同一性が slug のみで、evict→再claim とゾンビセッションの交錯で二重勝者・他者claim破壊 | **採用**。「自claim = slug+agent 一致」を §8.0 で定義（I-OWNER）し、done/sync/merge の全検査・全 WRITE-STATE precheck に組み込み。喪失は新設 exit 8。merge 手順11は手順1スナップショット照合 |
| 運B1/復C3 | install 直後の .agents 公開 push が自前フックに拒否されるブートストラップ・デッドロック（回避手段の学習を強制） | **採用（代替案）**。フック側の初期化例外（運B1案B）は却下し、install.sh 自身が一時 index の plumbing でブートストラップ commit+push を行う（§10 手順8）。トークンはユーザー向け出力に一切出さない |
| 運B2c/復C2 | core.hooksPath（husky等）で pre-push 防壁が無言消滅、install/sync とも無検知 | **採用**。install.sh は実効フックパスへ設置（repo外パスは書かず赤字警告）、sync の警告判定を「実効パス上のマーカー＋守備ブランチ名の照合」に変更（§8.3/§10 手順6） |

### major

| ID | 指摘（要約） | 裁定 |
|---|---|---|
| 並A3 | 遅延ブランチ削除が tip 検証なしで、merge中の done 再実行分を消す | **採用**。削除を `--force-with-lease=refs/heads/<branch>:<BR>` に変更、merge log に `branch_tip` 記録（§8.6 手順12a） |
| 並A4 | merge 手順2〜9の長い窓（フルテスト中）に新 directive を見ない | **採用**。手順9の push 直前（再走のたび）に READ-STATE 1回で maxd 再確認、増えていれば全文表示して exit 3。done/merge の --seen 復唱 precheck は「ループ内で maxd 再計算」と明記（§8.5 手順4 / §8.6 手順2・9） |
| 並A5 | 「push 適用済みだが応答喪失」の後始末未定義（幽霊claim / lease 恒久拒否） | **採用**。WRITE-STATE の致命 push 失敗時に1回だけ再fetch＋祖先検査で冪等化（§5.2）。done 手順7の push 直前に branch fetch を追加（§8.5） |
| 並A6 | merge ロック解放経路が本文矛盾（finally参照先が不在 / 手順4・5に解放なし / 無条件解放が他者ロックを消す） | **採用**。独立 op「UNLOCK」（precheck: lock.agent==run_token、不成立は警告のみ）を定義し、手順3以降の全失敗パスが経由（§8.6b）。手順11の複合コミットは成功経路専用と明記 |
| 並A7 | agent-state への force push が防げず検知もされず、seq 再採番で seen ゲート素通し | **採用**。フックの拒否対象に state ブランチを追加（AGENTS_STATE_TOKEN、§9）。READ-STATE に巻き戻り検知（旧tracking値の祖先検査、§5.1）。GitHub 推奨設定に agent-state の force push 禁止を明記 |
| 運B2a,b/復C9 | --no-verify・トークン手動設定が禁止事項に無く、フックが回避手段を自己文書化 | **採用**。§11章6に逐語で追加、フックのエラー文言に回避禁止を明記、説明コメント削除。変数名がコード上見えること自体は不可避（判定に必要）と認め、文言と禁止で埋める |
| 運B3 | プレイブック見出し「pushが拒否された: 正常」が誤スコープ、必須症状5件欠落 | **採用**。見出し改名＋「フックに拒否された=停止命令」を新設、症状項目を追加（§11章4） |
| 運B4 | worktree 内に .agents が現れない期間の実行パス案内なし、worktree外 sync の延命不発が無警告 | **採用（大半はブートストラップ push で構造解消）**。start 出力に絶対パス明記、worktree 外 sync に「延命されない」注記（§8.2/§8.3） |
| 運B5 | 口頭指示の directive 記録忘れが構造的に無防備 | **採用（文言の二重化）**。構造強制は原理的に不可能と認め、directive 以外の全コマンド出力末尾に固定リマインド行、ゲート通過時にも表示、PROTOCOL 章1を行動単位の文に（§8.0/§11） |
| 運B6 | --allow-lost-symbols が「その場しのぎフラグ」そのもので抑止ゼロ | **採用**。--reason 必須化、merge log に allowlist+reason 記録、exit 7 文言に「ユーザー明示承認なしの使用禁止」、§11章6に追加（§7/§8.6 手順7） |
| 復C4 | merge が手順9成功直後に死ぬと、再実行が偶然の「Already up to date」に依存し監査ログが嘘をつく | **採用**。手順4b「既マージ検出」を新設: BR が M_SHA の祖先なら回収経路（テスト省略、first-parent 走査で実マージコミット特定、recovery ログ、後片付け）へ短絡（§8.6） |
| 復C5/並A8/運B10 | ロックTTL30分 < テスト時間で生きた merge の横取りが常態化 | **採用**。テスト開始直前（再走ごと）に acquired_at を更新するハートビート（precheck 不成立は警告のみで続行）。config 生成コメントと PROTOCOL に「TTLはテスト所要の2倍以上」、奪取警告に「手動修復不要」を明記（§8.6 手順8）。「直近テスト実行時間の記録による自動検出」（並A8後段）は永続記録が要るため**却下**し、ハートビート＋文言で本質を守る |
| 復C6 | start 途中死の幽霊claim・agents.json欠如にプレイブック項目なし | **採用**。§11章4に症状2項目を追加（release --force への動線、agents.json の手書き復元手順）。evict/sync は「worktree 不在 claim」を注記表示（別クローンの可能性を併記、evict 条件自体は TTL のまま=クローン跨ぎ誤爆防止のため対象化は**却下**） |
| 復C7 | install.sh 手順7が push 失敗を全て「先客あり」と誤読し無限空振り | **採用**。install.sh も §5.3 の分類を適用し、CAS系のみ成功扱い、他は stderr 全文で exit 1。最後に ls-remote で存在検証（§10 手順7） |
| 復C8 | main_branch≠main の repo で防壁が誤った ref を守り続け無検知 | **採用**。install.sh が `ls-remote --symref HEAD` で default branch を検出して config に書き込み。sync がフック内の守備ブランチ名と config を照合。§3.1 にパターン非該当 fetch 失敗の助言つき exit 6 を明記 |

### minor（採用）

- 並A8/運B10 → ハートビートとして採用（上記）。復C10: merge 再走の戻り先矛盾を「手順4から」に統一。復C11: done の既存PR base 検証+矯正。復C12: sync/status に孤児 worktree 一覧（ローカルのみ。origin の agent/* 一覧はコマンド例を付録に記載する代替）。復C13: symlink の CLAUDE.md を実体化させない追記方式。復C14: start ロールバックに precheck、worktree add 再試行前に残骸 branch -D。復C15: stale 表示に「--dry-run で確認してから」+ 長時間離席後の sync を PROTOCOL に。
- 運B7: --seen 完成形コマンドを出力先頭に置かず directive 全文の後に。運B8: evict 文言変更（ユーザーに報告してから片付け）+ `--lock-only` 追加。運B9: 自claim喪失の sync を exit 8 に（警告は出力1行目）。運B11: branch protection の正確な設定名（require PR系は非互換と明記）+ GitHub Web UI マージボタンを禁止事項に。運B12: sync/status に主checkout の追跡ファイル dirty 警告 + merge の worktree外 slug 省略= exit 2 を明記。

### 却下・代替（理由つき）

- 運B1案B（フックの初期化例外: remote に CLI が無い間だけ素通し）: フックが fetch/remote 状態に依存して遅く・不安定になり、恒久的な例外経路が残る。install.sh 自身の push で置換。
- 運B8後段（evict の slug 指定）: `release <slug> --force` が同じ効果を持ち、同一効果への二経路は AI を迷わせる。`--lock-only` のみ採用。
- 並A8後段（test_cmd 実行時間の記録と TTL 比較警告）: 実行時間の永続化ストアが必要になり複雑化。静的な設定指針＋ハートビートで本質（横取り防止）は満たせる。
- 復C6後段（worktree 不在 claim を TTL 無視で evict 候補化）: worktree パスはマシンローカルで、別クローン運用時に健全な claim を誤爆させる。「注記表示のみ・evict は TTL のみ」に代替。
- 並A4後段（merge 手順9で directive 検知時のテスト省略再開）: 再テスト不要の特殊再開経路は手順を分岐させる。exit 3 → --seen つき再実行（フルテスト再走）に単純化。稀事象のテスト1回分は簡潔さの対価として払う。

---

## 0. 全体像

- 調整媒体は origin 上の orphan ブランチ **`agent-state`**。中身は小さな JSON ファイル群。
- 状態変更は必ず「新コミットを作って `git push`」。push の fast-forward 検査が **CAS**（compare-and-swap）になる。push 拒否は異常ではなく「他セッションが先に状態を変えた」という正常イベントで、fetch → 前提再評価 → リトライで解決する。
- `agent-state` の歴史は**一直線**（マージコミット禁止・force push 禁止。フックと巻き戻り検知で強制）。このコミット順が時計に依存しない全順序であり、その順序を写した整数 **seq**（`counter` ファイルで採番）が「後勝ち」の判定基準。**時刻は順序判定に一切使わない**（TTL の鮮度判定と表示のみ）。
- 実装作業は claim ごとの専用 worktree（`origin/main` の明示 SHA から作成）で行い、main への反映は直列化された `agents merge` だけが行う。main と agent-state への直接 push は clone ローカルの pre-push フックで拒否する。
- `.agents` 一式は install.sh 自身が main へ push するため、導入直後から全 worktree に CLI が存在する（ブートストラップ・デッドロックなし）。

```
ユーザー ──口頭指示──▶ 各AIセッション
   AI: agents directive "指示原文"      → agent-state に台帳記録（seq採番）
   AI: agents start <slug> ...          → claim(CAS) + worktree(SHA固定) + branch
   AI: （実装。定期的に agents sync）    → 新directive監視・claim延命
   AI: agents done                      → rebase → 全テスト → push → PR(任意)
   AI: agents merge <slug>              → ロック → 新規worktreeでマージ＝シミュレーション
                                          → シンボル消失チェック → 全テスト
                                          → push直前のdirective再確認 → main push(CAS)
                                          → 反映確認 → log記録/claim解除 → lease付き遅延ブランチ削除
```

---

## 1. 未決事項の決定一覧（BRIEF §「設計者が確定させるべき未決事項」全8件）

| # | 論点 | 決定 | 理由 |
|---|------|------|------|
| 1 | agent-state の読み書き実装 | **plumbing 方式**（`GIT_INDEX_FILE` に一時 index + `hash-object`/`read-tree`/`write-tree`/`commit-tree` + SHA 指定 push）。隠し worktree は不採用 | 同一クローンを複数ターミナルが共有する場合、共有 worktree は「共有可変資源」そのもので、checkout・index の排他が必要になり本末転倒。plumbing は主 index・HEAD・作業ツリーに一切触れず、書くのは immutable なオブジェクトと remote-tracking ref だけ。デバッグは `git log --oneline --stat refs/remotes/origin/agent-state` で可能（§5.4） |
| 2 | セッション識別 | **`start` 時に `secrets.token_hex(3)` で agent トークンを生成**し、claim ファイルと worktree の**専用 gitdir**（`git rev-parse --absolute-git-dir` が返す `.git/worktrees/<name>/` 配下の `agents.json`）に永続化。環境変数は不採用。**「自 claim」は常に slug+agent の組で同定**（I-OWNER。slug 一致だけでは自 claim ではない） | Claude Code / Codex の Bash 呼び出しはシェル状態が持続せず env は信頼できない。claim 前に識別子が要る問題は「識別子の生成と claim を `start` 内で一体化」して解消。gitdir 配下は作業ツリー外なので誤コミット不能、worktree 削除で自然消滅。agent 一致検査は evict→同 slug 再claim とゾンビセッションの交錯（二重勝者）を防ぐ |
| 3 | パス重複判定の粒度 | **機械判定はパスのみ2規則**（§6: 現行ツリーへの fnmatch 展開の交差 + ワイルドカード前プレフィックスの包含）。「触るインターフェース」宣言は claim の任意フィールドとして**表示専用**（start/sync が他 claim の intent/interfaces を必ず表示） | 意味の重複は機械判定不能。機械は「安全側に倒した過検出」だけを担い、意味判断は表示を見た AI の義務としてプロトコルに固定。glob 同士の厳密交差判定は過剰設計 |
| 4 | directive 矛盾の確認タイミング | **4点で強制**: (a) start 時（claim に `seen`=当時の最大 seq を記録。start が全 directive を表示）、(b) done、(c) merge 開始時、(d) merge の main push 直前（再走のたび）。done/merge は「claim.seen より新しい directive」が存在する限り、**現在の最大 seq を `--seen` で復唱**しない限り exit 3 で拒否。復唱成功で claim.seen を CAS 更新（監査証跡）。maxd の計算は必ず CAS ループ内の precheck で毎回行う | 矛盾判定は意味の問題で機械化不能。機械にできる最大限は「見ていないものを見ずに進めることを物理的に不可能にする」＋「見たという事実を台帳に残す」。復唱（最大 seq のエコー）は出力を読まないと書けない値であり、読み飛ばしを防ぐ。(d) はフルテストという最長工程の間に届いた directive を main 反映前に必ず可視化する |
| 5 | テストコマンド規約 | **`.agents/config.json` の `test_cmd`（sh -c で worktree ルート実行）**。未設定（キー欠落 or null）のとき done/merge は exit 3 で**拒否**。テスト無し repo は明示的に `"test_cmd": "true"` と書く。`--no-test` フラグは設けない | 実敗 #1/#8 はテスト省略が原因。省略を「設定ファイルに明示的に書かれた選択」としてのみ許し、その場しのぎのフラグでは許さない（構造で防ぐ）。`--allow-lost-symbols` も同思想で --reason 必須＋ログ記録＋ユーザー承認要件で抑止する（§7） |
| 6 | worktree 配置場所 | **repo 内 `.worktrees/`**（`worktree_root` で変更可）。install.sh が `.gitignore` に `/.worktrees/` と `/.agents/config.json` を追記 | Codex 等のサンドボックスは cwd 外書込を制限しうるため repo 内が安全側。config.json は**クローンローカル**（コミットしない）: worktree 内コピーが ROOT の編集を隠す事故を防ぎ、`test_cmd` の変更が全セッションに即時反映される。プロトコル上、ビルド・テストは常に worktree 内 cwd で実行される |
| 7 | gh 無しフォールバック | **merge は常にローカルマージ + `push origin HEAD:main` の一本道**。gh は done での PR 作成（レビュー可視化の砂糖）にのみ使い、失敗しても警告のみ。既存 PR は base を検証し main でなければ矯正（実敗 #7 の gh 層残滓の封じ）。`gh pr merge` は全面禁止（実敗 #2）。gh 無し環境は「PR 作成がスキップされる」だけで挙動は同一 | マージ経路が2本あると片方だけ壊れる。危険な方（gh pr merge）を捨て、安全な方に一本化すればフォールバックという概念自体が消える。BRIEF の「done に直マージモード」案はこの一本化に置き換える |
| 8 | main 直接 push 防止 | **clone ローカル `pre-push` フック**（install.sh が実効フックパスへ設置。core.hooksPath 対応）。`refs/heads/<main>` は `AGENTS_MERGE_TOKEN`、`refs/heads/<state>` は `AGENTS_STATE_TOKEN` が無い push を拒否。両トークンは `agents` CLI と install.sh の内部だけが立て、**ユーザー向け出力には一切書かない**。GitHub branch protection は前提にせず推奨設定として文書化 | フックは全ターミナル・全 worktree に自動適用される。agent-state も守ることで counter 巻き戻し→seq 再採番→seen ゲート素通しの経路を塞ぐ（READ-STATE の巻き戻り検知 §5.1 と二重化）。別クローンには install.sh 再実行で対応 |

---

## 2. 不変条件（実装が常に保証する性質）

1. **I-LINEAR**: `agent-state` の歴史は一直線。CAS 敗北時は決してマージせず、新 tip の上に作り直す。force push しない。READ-STATE は tip の巻き戻りを検知したら全操作を停止する（§5.1）。
2. **I-CAS**: 状態の読み→前提評価→書きは、push 成功まで何度でも「fetch し直して前提を再評価」する。前提評価（maxd 計算・所有者検査・staleness を含む）をループ外に置いてはならない。
3. **I-ORDER**: 順序の比較はすべて seq 整数（または agent-state のコミット祖先関係）。wall clock を順序に使わない。
4. **I-SHA**: worktree は必ず明示 SHA（fetch 直後に読んだ `refs/remotes/<remote>/<main>` の値）から作る。「今 checkout されているもの」を基点にしない（実敗 #4）。
5. **I-SERIAL-MERGE**: main を進める push は `agents merge` の手順 9 のみ。main push 自体が FF 検査＝最終 CAS であり、merge ロックは無駄なテスト実行を防ぐ最適化。ロックが破られても安全性は push の FF 検査で保たれる（防御の二重化）。ロック保持中はテスト開始ごとにハートビートで延命する。
6. **I-TEST-EACH**: main に載る候補のマージ結果ごとに、その結果そのものに対して build+test を実行してから push する（実敗 #1/#5/#8）。
7. **I-CLEAN-WT**: マージは毎回新規 worktree で行い、作成直後に `git status --porcelain` 空を検査する（実敗 #3）。
8. **I-VERIFY-THEN-DELETE**: ブランチ削除は (a) マージコミットが `origin/main` の祖先になったこと、かつ (b) 削除対象の tip が検証時の `BR` から動いていないこと（`--force-with-lease=<ref>:<BR>`）の両方を確認した後のみ（実敗 #6 + done 再実行分の保護）。
9. **I-NO-STACK**: `start` は base の指定を受け付けず常に `origin/main` SHA を base とするため、積み PR は構造的に作れない（実敗 #7）。gh で手動 base 指定 PR を作ることは禁止事項。done は既存 PR の base を検証し矯正する。
10. **I-LOCAL-ONLY**: 触ってよいのは対象 repo と repo 内 `.worktrees/`、および origin の `agent-state`/`agent/*` ブランチのみ。`~/.claude` 等グローバル設定には一切触れない（repo 外を指す core.hooksPath にも書かない）。
11. **I-OWNER**: 「自 claim」= `claims/<slug>.json` が存在し **かつ** `claim.agent == 自 agents.json の agent`。この同一性検査を、claim を読む・書く全経路（done/sync/merge/release/start ロールバック）の precheck に置く。不成立は原則 exit 8（claim 喪失）。

---

## 3. 同一クローン共有の安全性（一級市民）

想定: ユーザーは**同じディレクトリ**（同じ clone）で複数ターミナルを開き、各ターミナルで別の AI が `agents` を並行実行する。共有される可変資源を全列挙し、方針を固定する。

| 共有資源 | 方針 |
|---|---|
| 主 checkout の index / HEAD / 作業ツリー | **一切触らない**。状態操作は `GIT_INDEX_FILE`=一時ファイルの plumbing。実装作業は各自の worktree（専用 index/HEAD を持つ）内のみ。sync/status は主 checkout の追跡ファイル dirty を警告表示する（書き込み検知の代替） |
| `FETCH_HEAD` | **読まない**。他セッションの任意の fetch で随時上書きされるため。読むのは常に明示 refspec で更新した `refs/remotes/<remote>/<branch>` |
| remote-tracking ref（`refs/remotes/...`） | 並行 fetch/push でロック競合（`cannot lock ref` 等）が起きうる。**§3.1 リトライ規約**で吸収。ref は前進しかしない（巻き戻りは §5.1 が検知して停止）ため、どのセッションの fetch が勝っても結果は単調 |
| オブジェクト DB (`.git/objects`) | 内容アドレスで immutable、git の書込は tmp+rename でアトミック。並行書込は安全。push 前の未参照オブジェクトは `gc.pruneExpire` 既定 2 週間の猶予で保護される（追加対策不要と明記） |
| hooks（実効フックパスで共有） | pre-push フックは無状態の判定のみ（§9）。並行実行安全 |
| `.git/worktrees/<name>/` 名前空間 | worktree 名は `<slug>-<agent>` / `merge-<token>` で一意。`git worktree add/remove` の内部ロック競合はリトライ規約対象 |
| `.git/config` | 読み取りのみ（install.sh を除く） |
| 一時 index | `<common-gitdir>/agents-tmp/idx-<pid>-<token>`。名前衝突なし。finally で削除 |
| 同一 worktree に 2 ターミナル | プロトコルで禁止（§11 鉄則）。最終防衛は git 自身の `index.lock` |

補足: repo ルートの発見は `git rev-parse --path-format=absolute --git-common-dir` の親ディレクトリ（basename が `.git` でなければ bare とみなし exit 3）。これにより worktree 内から実行しても常に主 clone を特定できる。

### 3.1 リトライ規約（git ref ロック競合）

- 全 git サブプロセスは `env LC_ALL=C LANG=C` で起動する（stderr 文字列判定を安定させるため。必須）。
- **fetch / worktree add / worktree remove** の失敗で stderr が次のいずれかにマッチしたら再試行: `cannot lock ref` / `could not lock` / `Unable to create` かつ `.lock` / `unable to update local ref`。最大 **5 回**、待ち `uniform(0.1, 0.5)` 秒。超過で exit 6。
- パターン非該当の fetch 失敗（例: `couldn't find remote ref`）は即 exit 6 とし、stderr 全文に加えて「config.json の `remote` / `main_branch` / `state_branch` が実 repo と一致しているか確認せよ。既定ブランチが main でない repo は install.sh が検出するが、手で config を変えた場合は install.sh を再実行せよ」という助言を必ず添える。
- **push の CAS 敗北**は §5.3 のパターン表で判定する（最大 10 回）。それ以外の push 失敗は §5.2 の冪等化検査を1回だけ行った後、exit 6 で stderr 全文を表示。
- 成功した push 後の remote-tracking ref 更新警告は無視してよい（次の fetch で追いつく）。
- worktree add がブランチ作成後に失敗して再試行する場合、先に `git worktree remove --force <path>`（失敗無視）と `git branch -D <branch>`（失敗無視）で残骸を消してから再試行する（`already exists` での即死防止）。

---

## 4. データモデル（`agent-state` ブランチ）

### 4.1 ツリー構造

```
counter                      # 最終採番 seq。10進整数 + 改行のみ（例: "57\n"）
README.md                    # 人間向け 3 行説明（install が生成）
directives/d00042.json       # 指示台帳。1 指示 1 ファイル。seq をゼロ詰め5桁でファイル名に
claims/<slug>.json           # 担当宣言。1 担当 1 ファイル。slug がキー（seq は持たない）
locks/merge.json             # グローバル merge ロック。存在＝保持中
log/e00057-<kind>-<slug>.json# 完了・解除・追い出しの記録。kind ∈ {merge, release, evict}
```

- JSON の書式は全ファイル共通で `json.dumps(obj, ensure_ascii=False, indent=1, sort_keys=True) + "\n"`。決定的なバイト列にし、同内容の再書込が同一 blob になるようにする。
- seq を消費するのは **directive 追加と log 追加のみ**。消費する commit は同時に `counter` を更新する。claim は slug で一意なので seq 不要。
- `agent-state` 上のテキストコンフリクトは原理的に発生しない: 歴史が一直線（I-LINEAR）でマージ自体が無く、同名ファイルへの同時書込は CAS で必ず片方が敗北して前提再評価に落ちるため。

### 4.2 directives/d%05d.json

```json
{
 "by": "a3f2c9",
 "recorded_at": "2026-08-30T12:00:00Z",
 "scope": "ログイン画面のボタン色に関する指示",
 "seq": 42,
 "supersedes": [12],
 "text": "あ、やっぱりボタンは赤で"
}
```

- `seq` (int, 必須): 採番値。ファイル名と一致。
- `text` (str, 必須): ユーザー指示の**原文**。要約しない。
- `scope` (str, 必須, 空文字可): 記録した AI による解釈スコープ 1 行。
- `supersedes` (int配列, 省略可): 明示的に上書きする旧 directive の seq。存在しない seq を指していたら警告表示のみで記録は続行。
- `by` (str, 必須): 記録セッションの agent トークン。claim worktree 外からの記録は `"main"`。
- `recorded_at` (str, 必須): 記録側ローカル時計の ISO8601 UTC。**表示専用**。順序判定に使うことを禁ずる。

### 4.3 claims/&lt;slug&gt;.json

```json
{
 "agent": "a3f2c9",
 "base_sha": "0123abcd...40桁",
 "branch": "agent/a3f2c9/login-ui",
 "claimed_at": "2026-08-30T12:00:00Z",
 "directive": 42,
 "intent": "ログイン画面の実装",
 "interfaces": ["AuthService.login"],
 "paths": ["src/auth/**", "tests/auth/**"],
 "refreshed_at": "2026-08-30T12:34:00Z",
 "seen": 42,
 "slug": "login-ui",
 "status": "active",
 "worktree": ".worktrees/login-ui-a3f2c9"
}
```

- `slug` (str): `^[a-z0-9][a-z0-9-]{0,39}$`。予約語 `merge`, `state`, `evict` は不可。
- `agent` (str): `secrets.token_hex(3)`（6 hex 文字）。branch 名に埋まるため、同 slug の再claim でも branch は衝突しない。
- `branch` (str): 常に `agent/<agent>/<slug>`。
- `directive` (int): 紐づく directive の seq。全 claim は必ずどれかの directive に紐づく。
- `paths` (str配列, 1個以上): 触るパスの glob（repo ルート相対、`/` 区切り）。
- `interfaces` (str配列, 省略時 `[]`): 触る意味的インターフェースの自由記述。**表示専用**。
- `intent` (str): 1 行意図。
- `base_sha` (str): worktree の基点にした `origin/main` の 40 桁 SHA（I-SHA）。
- `status` (str): `"active"` | `"ready"`（done 完了で ready）。
- `seen` (int): ack 済みの最大 directive seq（§1 決定 4）。
- `claimed_at` / `refreshed_at` (str): ISO8601 UTC。`refreshed_at` のみ TTL 鮮度判定に使用。
- `worktree` (str): repo ルート相対の worktree パス（表示・片付け案内用。**マシンローカル情報**であり、別クローンでは存在しなくて正常）。

### 4.4 locks/merge.json

```json
{
 "acquired_at": "2026-08-30T13:00:00Z",
 "agent": "7c1d2e",
 "slug": "login-ui",
 "ttl_min": 30
}
```

- `agent` は **merge 実行ごとに生成する run token**（`token_hex(3)`。claim の agent ではない。merge は worktree 外から他人の ready claim に対しても実行できるため、ロックの同一性は実行単位で持つ）。
- stale 判定: `now_utc - acquired_at > ttl_min`。stale なロックは merge 取得時に**置換**（同一 CAS commit 内で削除+作成）してよい。
- 保持者は build+test の開始直前（再走ごと）に `acquired_at = NOW` へハートビート更新する（§8.6 手順 8）。これによりテストが TTL より長い repo でも生きたロックは stale にならない。
- ロックは最適化であり安全性は main push の FF 検査が担う（I-SERIAL-MERGE）。

### 4.5 log/e%05d-&lt;kind&gt;-&lt;slug&gt;.json

merge の例:

```json
{
 "agent": "a3f2c9",
 "allowed_lost": [],
 "branch": "agent/a3f2c9/login-ui",
 "branch_tip": "cdef....",
 "directive": 42,
 "kind": "merge",
 "main_after": "89ab....",
 "main_before": "0123....",
 "merge_commit": "4567....",
 "merged_at": "2026-08-30T13:05:00Z",
 "recovery": false,
 "seen": 47,
 "seq": 57,
 "slug": "login-ui",
 "tests": "pass"
}
```

- `branch_tip`: マージ検証時の BR（手順 12a の lease 削除の期待値。監査でどのコミットが入ったかを直接示す）。
- `allowed_lost` / `reason`: `--allow-lost-symbols` 使用時のみ、許可したシンボル一覧と `--reason` の文字列。未使用時は `[]` / 省略。
- `recovery` (bool): 手順 4b の既マージ回収経路で書かれた log は true。`merge_commit` は first-parent 走査で特定した実マージコミット（特定不能なら null。その場合 `main_before`/`main_after` も null とし、§13 の鎖検証では recovery エントリを注記付きで除外する）。
- `kind:"release"` は `slug, agent, seq, released_at`、`kind:"evict"` は `seq, evicted:[{slug, agent, refreshed_at}], lock_evicted:bool, evicted_at` を持つ。

### 4.6 時計に依存しない後勝ち全順序（正規の定義）

1. `agent-state` は一直線の歴史であり、**コミットの祖先関係が全順序**。
2. seq は CAS 直列化の下で「読んだ counter + 1」を採番するため、**seq の大小はコミット順と一致**する。読む側はファイル名の seq だけで順序を復元でき、`git log` を歩く必要がない。
3. 「後勝ち」= 矛盾する directive 群のうち **seq 最大が正**。`supersedes` は表示の補助であり順序の根拠ではない。
4. wall clock（`*_at` フィールド）は TTL 鮮度判定と人間向け表示にのみ使う。TTL（claim 24h / lock 30min）はクロックスキューより十分大きく取り、スキュー数分は無害と文書化する。
5. 1・2 の前提「歴史が巻き戻らない」は、pre-push フックの state 保護（§9）と READ-STATE の巻き戻り検知（§5.1）で観測可能に強制する。巻き戻りが検知されたら seq の一意性が保証できないため全操作を停止する。

---

## 5. 状態読み書きプロトコル（正確なコマンド列）

以下、`R`=remote 名（既定 `origin`）、`S`=state ブランチ名（既定 `agent-state`）、`M`=main ブランチ名（既定 `main`）。全 git 呼び出しは `LC_ALL=C LANG=C` 付き、cwd は repo ルート（`-C ROOT`）。

### 5.1 READ-STATE

```
0. OLD = git rev-parse -q --verify refs/remotes/R/S（無ければ None。初回）
1. fetch（リトライ規約 §3.1）:
     git fetch --quiet R +refs/heads/S:refs/remotes/R/S
   ※ 明示 refspec を使う（--single-branch クローンでも動くように）。
2. TIP = git rev-parse refs/remotes/R/S
   失敗 → exit 3「agent-state が無い。install.sh を実行せよ」
3. 巻き戻り検知: OLD があり `git merge-base --is-ancestor OLD TIP` が偽 → exit 6:
   「agent-state が巻き戻されている（force push の痕跡）。seq の一意性が保証できないため
    全操作を停止した。ユーザーに報告せよ。ユーザー自身による意図的なリセットの場合のみ、
    各クローンで git update-ref -d refs/remotes/R/S を実行してから再実行」
4. 一覧: git ls-tree -r --name-only TIP
5. 内容: 必要ファイルごとに git cat-file blob TIP:<path>
   counter が無ければ 0 とみなす。JSON パース失敗はファイル名を添えて exit 6。
```

### 5.2 WRITE-STATE（CAS。全状態変更はこの 1 関数を通る）

擬似コード（実装はこの構造を忠実に写す）:

```
PUSH_CAS_PATTERNS = [ r"\[rejected\]", r"non-fast-forward", r"fetch first",
                      r"\[remote rejected\]", r"incorrect old value",
                      r"failed to update ref", r"cannot lock ref" ]
  # 後段4つは「advertise〜ref更新の窓に他pushが着地した」CAS本命レースの実測パターン
  # （git 2.53.0 実測: "! [remote rejected] ... (incorrect old value provided)"。
  #   旧git: "failed to update ref" + "cannot lock ref ... but expected"）。
  # branch protection 等による恒久的 remote rejected もこの分類に落ちるが、
  # リトライ上限の exit 5 が stderr 全文を表示するので診断可能（安全側）。

def write_state(precheck, mutate, msg, on_precheck_fail="exit"):
    for attempt in range(10):                      # CAS_MAX = 10
        st = READ_STATE()                          # 毎回 fetch + 巻き戻り検知
        err = precheck(st)                         # 前提評価は必ずループ内（I-CAS）
                                                   # maxd 計算・I-OWNER 検査もここで毎回行う
        if err:
            if on_precheck_fail == "skip":         # heartbeat / UNLOCK 専用の変種
                warn(err.msg); return None
            exit(err.code, err.msg)                # 3(前提) / 4(競合) / 8(claim喪失)
        changes = mutate(st)                       # [("put", path, bytes) | ("del", path)]
        TMPIDX = COMMON_GITDIR/"agents-tmp"/f"idx-{pid}-{token_hex(4)}"
        try:
            env GIT_INDEX_FILE=TMPIDX:
                git read-tree {st.tip}^{tree}
                for ("put", path, content):
                    BLOB = git hash-object -w --stdin   <<< content
                    git update-index --add --cacheinfo 100644,BLOB,path
                for ("del", path):
                    git update-index --force-remove path
                TREE = git write-tree
            COMMIT = git -c user.name=agents-kit -c user.email=agents-kit@local \
                       commit-tree TREE -p {st.tip} -m msg
            r = env AGENTS_STATE_TOKEN=1 git push --quiet R COMMIT:refs/heads/S
        finally:
            rm -f TMPIDX
        if r.ok: return COMMIT
        if r.stderr =~ any(PUSH_CAS_PATTERNS):
            sleep(uniform(0.2, 1.0) + 0.1 * attempt)   # CAS 敗北 = 正常イベント
            continue
        # 致命系の前に「適用済みだが応答が届かなかった」を 1 回だけ検査（書込の冪等化）:
        try: fetch S（§3.1）; if git merge-base --is-ancestor COMMIT refs/remotes/R/S: return COMMIT
        except: pass                               # 再fetchも失敗なら元のstderrで落とす
        exit(6, r.stderr)                          # それ以外の push 失敗は致命
    exit(5, "CAS リトライ上限。少し待って再実行せよ。最後の stderr:\n" + last_stderr)
```

要点:

- ident は repo/グローバル設定に依存させない（`-c user.name=agents-kit -c user.email=agents-kit@local`）。main に載る実コードのコミット（worktree 内の通常コミットとマージコミット）はユーザーの通常 ident のまま。
- コミットメッセージ規約: `directive d00043` / `claim login-ui (a3f2c9)` / `ready login-ui` / `seen login-ui 47` / `refresh login-ui` / `lock merge login-ui` / `heartbeat merge login-ui` / `unlock merge` / `merge-log login-ui` / `release login-ui` / `evict 2 claims`。デバッグ時に `git log --oneline` だけで流れが読める。
- ローカルに `agent-state` ブランチ（`refs/heads/S`）は**決して作らない**。SHA:refspec 形式の push だけを使う。ローカル ref が無ければ競合も無い。force オプションも決して使わない（フックの state 保護と整合）。
- seq 採番が要る mutate は `st` から counter を読み、`counter` 更新と本体ファイル追加を**同一 commit** に入れる。
- `on_precheck_fail="skip"` を使ってよいのはハートビート（§8.6 手順 8）と UNLOCK（§8.6b）だけ。他は必ず exit。
- 冪等化検査により「claim push 適用後に応答喪失」でも start は成功として続行し、幽霊 claim（所有者不明で slug を塞ぐ）は発生しない。

### 5.3 失敗分類表（push。WRITE-STATE と merge 手順 9 の両方に適用）

| stderr | 分類 | 挙動 |
|---|---|---|
| `[rejected]` / `non-fast-forward` / `fetch first` / `[remote rejected]` / `incorrect old value` / `failed to update ref` / `cannot lock ref` | CAS 敗北 | WRITE-STATE: ループ継続（≤10、上限で exit 5 + stderr 全文）。merge 手順 9: 再走（≤2、上限で exit 5 + stderr 全文） |
| `could not read` / 認証 / `Connection` 等その他 | 致命 | 冪等化検査 1 回（§5.2）の後 exit 6、stderr 全文表示 |

### 5.4 デバッグ手段（仕様の一部として文書化）

`git log --oneline --stat refs/remotes/R/S` が完全な監査ログ。`git show <sha>:claims/x.json` で任意時点の状態を読める。plumbing 方式の可視性はこれで担保する（PROTOCOL.md にも記載）。

---

## 6. パス重複判定アルゴリズム

入力: 新 claim のパス集合 A、既存 claim のパス集合 B、基準ツリー `base_sha`（fetch 直後の `refs/remotes/R/M`）。

```
files = git ls-tree -r --name-only base_sha の全行
kind(p)   = "literal"（* ? [ を含まない）| "pattern"
foot(pat) = 最初のワイルドカード文字より前の部分を最後の '/' まで切ったもの
            例: "src/auth/**" → "src/auth/", "src/a*.py" → "src/", "*.md" → ""
match(f, pat) = fnmatch.fnmatchcase(f, pat)
            ※ fnmatch では * も ** も '/' を跨いでマッチする。過検出（安全側）と明記。

overlap1(a, b):                        # 要素同士
  literal vs literal: a == b or a.startswith(b + "/") or b.startswith(a + "/")
  literal L vs pattern P: match(L, P) or L.startswith(foot(P))
  pattern vs pattern:
      {f in files | match(f, Pa)} ∩ {f in files | match(f, Pb)} ≠ ∅
      or foot(Pa).startswith(foot(Pb)) or foot(Pb).startswith(foot(Pa))
      ※ foot が "" の pattern（例 "*.md"）は全体と交差扱い（安全側）

overlap(A, B) = ∃ (a,b) ∈ A×B: overlap1(a, b) → その (a, b) ペアを報告
```

- literal の foot 包含・ツリー実マッチの二本立てにより「まだ存在しない新規ファイルを両者が同じディレクトリに作る」ケースも捕まえる。
- 過検出時の逃げ道はパス宣言を狭めること。緩和フラグは設けない。
- この判定は WRITE-STATE の precheck 内で行う（CAS ループ毎に再評価。I-CAS）。

---

## 7. シンボル消失チェックアルゴリズム（merge 手順 7 の詳細）

目的: 実敗 #2（コンフリクト解決や rebase 中の解決ミスで関数定義ごと消えたのに成功して見える）を、マージ結果に対する機械検査で捕まえる。

記号: `M`=マージ先 main SHA、`BR`=ブランチ tip SHA、`RES`=ローカルマージ結果コミット、`B0 = git merge-base M BR`。

```
changed = git diff --no-renames --name-only B0 BR の全行
対象   = changed のうち拡張子が §7.1 の表にあり、かつ全リビジョンで 1MB 以下のファイル
sym(rev, F) = git cat-file blob rev:F の内容に表の正規表現(MULTILINE)を適用し、
              マッチごとに最初の非 None キャプチャ群を集めた集合。ファイル欠如は ∅。

各 F について:
  added        = sym(BR,F) − sym(B0,F)          # ブランチが足したもの
  lost_added   = added − sym(RES,F)             # → 結果に無ければ消失
  removed_by_br= sym(B0,F) − sym(BR,F)          # ブランチが意図して消したもの
  lost_main    = (sym(M,F) − removed_by_br) − sym(RES,F)
                                                # main に居てブランチが消していないのに結果に無い
  violations  += {(F, s) for s in lost_added ∪ lost_main}

violations − allowlist(--allow-lost-symbols "name1,name2") が非空
  → 一覧を「file: symbol (added|main)」形式で表示し exit 7。merge worktree は調査用に残す。
検査対象外だったファイル（拡張子表に無い・サイズ超過）は「未検査」として一覧表示する。
```

`--allow-lost-symbols` の抑止（決定 5 と同思想。「その場しのぎフラグ」化を防ぐ）:

- `--reason "<1行>"` が**必須**。無ければ exit 2。
- 使用時は merge log（§4.5）に `allowed_lost` と `reason` を記録する（監査可能）。
- exit 7 の表示文言に必ず含める: 「まず merge worktree（<絶対パス>）で消失箇所を目で確認せよ。`--allow-lost-symbols` は**ユーザーの明示承認が無い限り使用禁止**（--reason 必須、agent-state に記録され監査される）」。完成形のコマンド例は表示しない。
- §11 章 6 の禁止事項に「ユーザー承認なしの --allow-lost-symbols」を追加。

### 7.1 言語別シンボル正規表現表（v1）

| 拡張子 | 正規表現（python `re`, MULTILINE。vb のみ IGNORECASE 追加） |
|---|---|
| .py | `^[ \t]*(?:async[ \t]+)?def[ \t]+([A-Za-z_]\w*)\|^[ \t]*class[ \t]+([A-Za-z_]\w*)` |
| .js .jsx .ts .tsx .mjs | `^[ \t]*(?:export[ \t]+)?(?:default[ \t]+)?(?:async[ \t]+)?function[ \t*]+([A-Za-z_$][\w$]*)\|^[ \t]*(?:export[ \t]+)?(?:abstract[ \t]+)?class[ \t]+([A-Za-z_$][\w$]*)\|^[ \t]*(?:export[ \t]+)?(?:const\|let\|var)[ \t]+([A-Za-z_$][\w$]*)[ \t]*=` |
| .go | `^func[ \t]+(?:\([^)]*\)[ \t]*)?([A-Za-z_]\w*)\|^type[ \t]+([A-Za-z_]\w*)` |
| .rs | `^[ \t]*(?:pub(?:\([^)]*\))?[ \t]+)?(?:async[ \t]+)?(?:fn\|struct\|enum\|trait\|mod)[ \t]+([A-Za-z_]\w*)` |
| .java .kt .scala | `^[ \t]*(?:(?:public\|private\|protected\|internal\|open\|final\|abstract\|static\|sealed\|data\|suspend\|override)[ \t]+)*(?:class\|interface\|enum\|object\|fun\|record)[ \t]+([A-Za-z_]\w*)` |
| .swift | `^[ \t]*(?:(?:public\|private\|internal\|open\|final\|static)[ \t]+)*(?:func\|class\|struct\|enum\|protocol\|extension)[ \t]+([A-Za-z_]\w*)` |
| .rb | `^[ \t]*def[ \t]+(?:self\.)?([A-Za-z_]\w*[?!=]?)\|^[ \t]*(?:class\|module)[ \t]+([A-Z]\w*)` |
| .sh .bash .zsh | `^[ \t]*(?:function[ \t]+)?([A-Za-z_]\w*)[ \t]*\(\)` |
| .vb | `^[ \t]*(?:(?:Public\|Private\|Friend\|Protected\|Shared\|Overrides\|Overloads)[ \t]+)*(?:Sub\|Function\|Class\|Module\|Property)[ \t]+([A-Za-z_]\w*)` |

C/C++ は正規表現での関数定義抽出が不安定なため v1 では対象外（未検査一覧に出る）。表は定数としてスクリプト先頭に置き、拡張はここに行を足すだけとする。

---

## 8. CLI `agents` 仕様

### 8.0 共通事項

- 実体: `.agents/bin/agents`。shebang `#!/usr/bin/env python3`、実行 bit 付き、python 3.9+、**標準ライブラリのみ**（使用想定: argparse, subprocess, json, os, sys, re, fnmatch, secrets, random, time, datetime, pathlib, shutil, tempfile）。git 2.30+ 必須。gh は任意。
- 起動時共通処理: (1) `git rev-parse --path-format=absolute --git-common-dir` で COMMON_GITDIR と ROOT を解決（git repo 外・bare は exit 3）。(2) config 読込: `<現在の worktree の toplevel>/.agents/config.json` → 無ければ `ROOT/.agents/config.json` → どちらも無ければ exit 3「install.sh を実行せよ」。JSON パース失敗 exit 3。未知キーは警告のみ。config.json はクローンローカル（.gitignore 対象。§1 決定 6）で、通常は ROOT のものだけが存在する。
- config スキーマと既定値:

```json
{
 "test_cmd": null,
 "build_cmd": null,
 "remote": "origin",
 "main_branch": "main",
 "state_branch": "agent-state",
 "worktree_root": ".worktrees",
 "claim_ttl_hours": 24,
 "merge_lock_ttl_min": 30,
 "pr": "auto"
}
```

  `worktree_root` は ROOT 相対（絶対パスも可）。`pr` は `"auto"`（gh があり remote URL に `github.com` を含む時だけ PR 作成）| `"off"`。`merge_lock_ttl_min` は**フルテスト所要時間の 2 倍以上**を推奨（install.sh 生成時のコメントと PROTOCOL に明記。ハートビートがあるため下回っても安全性は壊れないが、警告が増える）。
- **自 claim の定義（I-OWNER）**: `git rev-parse --absolute-git-dir` 直下の `agents.json`（`{"slug","agent","branch"}`）が示す (slug, agent) に対し、state 上の `claims/<slug>.json` が存在し**かつ** `claim.agent` が一致するもの。agents.json が無ければ「claim worktree 外」。ファイル存在＋slug 一致だけで自 claim と判定してはならない（evict→再claim 後のゾンビが新所有者の claim を壊す）。
- 出力は日本語の人間可読テキスト。`sync` / `status` は `--json` を持つ（後述のスキーマで機械可読）。テスト・ビルドの出力は**チャンク単位の無遅延 tee** で流す（読んだバイトを即 stdout へ転写しつつ、失敗表示用に末尾 `TEST_LOG_TAIL` 行を捕捉する。行バッファでの転写は禁止 — 改行を伴わない進捗出力が滞留して停止に見え、merge を殺す誘因になる）。(impl-fix: 旧文「そのまま継承して流す」は TEST_LOG_TAIL の捕捉要件と両立しないため tee 方式に統一)
- **固定リマインド行**: `directive` を除く全コマンドは、出力の最終行に必ず次を表示する:
  「※ ユーザーから受けた口頭指示で未記録のものは無いか? あれば次の行動より先に: agents directive "<指示の原文>"」
  （記録漏れは構造では防げない唯一の穴。機械的な反復表示で圧を掛ける）
- 終了コード（全コマンド共通の意味論）:

| code | 意味 |
|---|---|
| 0 | 成功 |
| 2 | 引数・使い方の誤り（argparse 既定） |
| 3 | 前提不成立（config 不足、claim worktree 外、dirty、未 ack directive、install 未実行） |
| 4 | 競合（slug 使用中、パス重複、merge ロック保持中、マージコンフリクト） |
| 5 | リトライ上限（CAS 10 回 / merge 再走 2 回）。stderr 全文を表示 |
| 6 | 外部コマンド失敗（git 致命エラー、build/test 失敗、worktree 作成失敗、state 巻き戻り検知） |
| 7 | 検証失敗（クリーン worktree 検査、シンボル消失、origin/main 反映確認） |
| 8 | claim 喪失（自 claim が evict/release され、または同 slug が別 agent に再claim されていた。作業を止めてプレイブック「claim が evict されていた」へ） |

- 曖昧さ回避の定義: 「fetch main」= `git fetch --quiet R +refs/heads/M:refs/remotes/R/M`（リトライ規約付き）。「NOW」= `datetime.now(timezone.utc)` の ISO8601（秒精度、`Z` 終端）。directive 引数は `d00043` / `d43` / `43` を受理し int に正規化。

### 8.1 `agents directive "<text>" [--scope "<1行>"] [--supersedes d12,d15] [--json]`

ユーザー指示原文の台帳記録。どこで実行してもよい。

1. text 空なら exit 2。
2. WRITE-STATE: precheck なし（常に受理。supersedes の参照先欠如は警告のみ）。mutate = `seq = counter+1` を採番し `directives/d%05d.json` 追加 + `counter` 更新。`by` は claim worktree 内なら自 agent、外なら `"main"`。msg = `directive d%05d`。
3. 出力: 1 行目に `d00043`（`start --directive` にそのまま渡せる形）。続けて text/scope の要約と「担当を取るなら: agents start <slug> --directive d00043 --paths ... --intent ...」。

### 8.2 `agents start <slug> --directive dNN --paths "<g1,g2,...>" --intent "<1行>" [--interfaces "<a,b>"]`

claim（CAS）+ SHA 固定 worktree + ブランチ作成を一体で行う。

1. 引数検証: slug 形式（§4.3）違反・paths 空・intent 空・directive 欠如は exit 2。paths はカンマ区切りで分割し前後空白を除去、先頭 `/` と `./` は剥がして正規化。
2. `agent = secrets.token_hex(3)`、`branch = agent/<agent>/<slug>`。
3. fetch main（base_sha 用。state の fetch は WRITE-STATE 内で毎回行われる）。
4. WRITE-STATE（msg = `claim <slug> (<agent>)`）:
   - precheck: (a) `directives/d%05d.json` が存在（無ければ exit 3「先に agents directive で記録せよ」）。(b) `claims/<slug>.json` 不在（在れば exit 4。相手の agent / intent / paths / 経過時間を表示し「別 slug にするか、agents sync で状況確認、必要なら agents evict --dry-run で生死確認」）。(c) §6 のパス重複が全既存 claim に対し無し（在れば exit 4。相手 slug / intent / 重複した (a,b) ペアを表示）。
   - mutate: 直前の READ-STATE と同ターンで `base_sha = git rev-parse refs/remotes/R/M` を読み直し、§4.3 の claim を作成。`seen` = 現在の最大 directive seq、`status` = `"active"`、`claimed_at` = `refreshed_at` = NOW。
   - CAS ループ内で毎回 (a)(b)(c) と base_sha を取り直す（I-CAS / I-SHA）。push 応答喪失は §5.2 の冪等化検査が成功へ倒す（幽霊 claim を作らない）。
5. worktree 作成: `git worktree add -b <branch> <ROOT>/<worktree_root>/<slug>-<agent> <base_sha>`（リトライ規約対象。再試行前の残骸掃除は §3.1 末尾）。失敗したら WRITE-STATE で claim を削除（msg = `release <slug>`、**precheck = claim 存在 ∧ claim.agent == 自 agent**。極端な競合で他者の再claim を消さないため）してから exit 6。
6. `git -C <wtpath> rev-parse --absolute-git-dir` 直下に `agents.json` を書く: `{"slug": ..., "agent": ..., "branch": ...}`。
7. 出力: worktree 絶対パス / branch / base_sha（短縮 12 桁）/ 紐 directive の text、他の active claim 一覧（agent, slug, intent, paths, interfaces）、直近 directive 5 件、最後に必ず:
   「cd <絶対パス> して作業せよ。以後の agents コマンドはその worktree 内で実行（実体はどの checkout にも入っている `.agents/bin/agents`。見つからない場合は絶対パス `<ROOT>/.agents/bin/agents` を使え）。定期的に agents sync（claim の延命は worktree 内での sync だけが行う）。」+ 固定リマインド行。

### 8.3 `agents sync [--all] [--json]`

fetch + 状態表示 + claim 延命。作業中の定期実行を義務づける（PROTOCOL）。

1. fetch state（READ-STATE）+ fetch main。
2. **自 claim 喪失検知**（最初に判定し、該当すれば警告を**出力の 1 行目**に置く）: worktree の agents.json はあるが、`claims/<slug>.json` が無い、または `claim.agent != 自 agent`（=同 slug が別セッションに再claim 済み）→ 「!! あなたの claim <slug> は失われた（evict/release/再claim）。作業を止め、PROTOCOL.md『claim が evict されていた』に従え」。表示は続行し、**最終 exit は 8**（--json では `warnings` に `"claim_lost"` を含める）。
3. 表示（この順で固定）:
   - `main:` `refs/remotes/R/M` 短縮 SHA。自 claim があれば base_sha からの遅れ（`git rev-list --count base_sha..refs/remotes/R/M`）。
   - `lock:` merge ロック（保持者 run-token/slug、経過分、stale なら `!! STALE — agents evict --dry-run で生死確認の上 agents evict --lock-only` を付す）。無ければ `なし`。
   - `claims:` 表形式で slug / agent / status / claimed_at からの経過 / refreshed_at からの経過（TTL 超は `!! STALE`）/ paths / intent。worktree パスがこのマシンに存在しない claim には `(worktree不在 — 別クローンの作業か、start 途中死の可能性)` を付す。
   - `directives:` 末尾 10 件（`--all` で全件）を seq 昇順で `d00043 [scope] text`（supersedes があれば `⊃ d12` を付す）。**自 claim の `seen` より新しい行の先頭に `!! NEW`**。
   - `孤児:` `<worktree_root>/` 直下のディレクトリのうち、どの claim の `worktree` とも一致しないもの（`merge-*` の残骸を含む）。「中身（未 push の作業）を確認し、ユーザーに報告してから片付けよ」を添える。
   - 警告ブロック:
     - test_cmd 未設定。
     - **フック検査**: 実効フックパス（`git config --get core.hooksPath` があればそれを ROOT 相対で解決、無ければ `COMMON_GITDIR/hooks`）の `pre-push` を 4 点で検査する: (i) マーカー `>>> agents-kit pre-push >>>` が有り、(ii) ブロック内に `refs/heads/<config.main_branch>` と `refs/heads/<config.state_branch>` の両文字列が有り、(iii) ブロックより前に実行文が無い（shebang・コメント・空行のみ。前段の早期 exit による到達不能化の検知）、(iv) マーカー間ブロック**だけ**を sh で合成 stdin 実行し、トークン無しの保護 ref push が非 0、トークン有りおよび非保護 ref が 0 になること（ユーザーの後続フック本体は実行しない＝副作用なし）。いずれか欠如 → 「main 直 push 防壁が実効フックパスに無い/不整合。install.sh を再実行せよ」。(impl-fix: 文字列存在のみの検査は「exit 0 の後ろの死んだブロック」を健全と誤報告するため (iii)(iv) を追加)
     - stale claim・lock の存在（stale claim には「evict の前に `agents evict --dry-run` で確認せよ。自分の別ターミナルが生きているかもしれない」）。
     - `!! NEW` があるとき「NEW を読み、自分の作業と矛盾しないか判断せよ。矛盾したら PROTOCOL.md『新 directive と矛盾したら』へ。done/merge には --seen d<最大seq> が必要」。
     - 主 checkout の追跡ファイル dirty（`git -C ROOT status --porcelain -uno` 非空）→ 「主 checkout が汚れている。AI セッションは ROOT に書き込むな（人間の作業なら無視してよい）」。
     - claim worktree 外での実行時 → 「注意: ここでは claim は延命されない。延命は作業 worktree 内の sync のみ」。
4. 延命: claim worktree 内かつ**自 claim（I-OWNER 一致）**が存在し、`NOW - refreshed_at > claim_ttl_hours/4` のとき WRITE-STATE で `refreshed_at = NOW` に更新（msg = `refresh <slug>`、precheck = claim 存在 ∧ agent 一致。不成立は手順 2 の喪失検知として扱う）。それ以外は書き込みしない（履歴の肥大防止）。
5. `--json`: `{"main_sha":..., "state_tip":..., "lock":..., "claims":[...], "directives":[...], "self":{"slug":...}|null, "orphans":[...], "warnings":[...]}` を 1 JSON で出力（表示テキストは出さない。exit code の意味は同一）。
6. 固定リマインド行。

### 8.4 `agents status [--json]`

`sync` の表示部のみ（fetch なし・書き込みなし・オフライン可）。`refs/remotes/R/S` が無ければ「未 fetch。agents sync を実行せよ」で exit 3。孤児 worktree 一覧と主 checkout dirty 警告は表示する（ローカル操作のみで可能）。gh が在れば `gh pr list --json number,headRefName,baseRefName,title,url`（3 秒タイムアウト）を試み、claims 表に PR 列を付ける。失敗は無言でスキップ（best-effort）。固定リマインド行。

### 8.5 `agents done [--seen dNN]`

自 worktree の成果を「マージ可能」状態にする: rebase → 全テスト → push → PR(任意)。

1. 自 claim 特定（agents.json）。無ければ exit 3「claim worktree 内で実行せよ」。
2. `git status --porcelain` が非空なら exit 3。一覧を表示し「全てコミットせよ（rebase 途中ならば解消して git rebase --continue）」。
3. READ-STATE。`claims/<slug>.json` が無い、**または `claim.agent != 自 agent`** → exit 8「claim は evict/release 済み、または同 slug が別セッションに再claim 済み。あなたの変更は claim に反映してはならない。PROTOCOL.md『claim が evict されていた』へ」。
4. **directive ゲート**: `maxd` = 最大 directive seq。`claim.seen < maxd` のとき:
   - `--seen` 無し → 未読 directive（seq > seen）を**全文**表示し、**その後に** exit 3「上記を読み、自分の作業と矛盾しないか判断せよ。記録漏れの口頭指示があるなら先に agents directive で記録せよ。矛盾が無いと判断した場合のみ、agents done --seen d%05d で復唱して再実行」（完成形コマンドを出力の先頭に置かない。読了前のコピペ通過を防ぐ。**全文と拒否文は同一ストリーム＝stdout に出す**: 拒否文を stderr に分けるとパイプ捕捉環境で stderr が先に flush され、完成形コマンドが全文より先頭に現れて本規定が無効化される (impl-fix)）。
   - `--seen != maxd` → 同上（さらに新しい directive が増えたケース。最新一覧を再表示）。
   - `--seen == maxd` → WRITE-STATE で `claim.seen = maxd`、`refreshed_at = NOW`（msg = `seen <slug> <maxd>`。**precheck はループ内で毎回**: claim 存在 ∧ agent 一致（不成立 exit 8）∧ maxd 再計算が --seen 値と一致（増えていたら exit 3 で最新を再表示））。続行。
5. fetch main → `git rebase refs/remotes/R/M`。コンフリクトで停止したら exit 6: 「解消 → git add → git rebase --continue → 再度 agents done」（rebase は進行中のまま渡す。手順 2 が再実行時の番人になる）。
6. build_cmd（設定時のみ）→ test_cmd を `sh -c`、cwd=worktree で実行。test_cmd 未設定（null）は exit 3「config.json の test_cmd を設定せよ（テスト無しなら \"true\" と明示）」。失敗は exit 6 **push しない**（実敗 #8 の構造化）。
7. `git fetch --quiet R +refs/heads/<branch>:refs/remotes/R/<branch>` を実行（`couldn't find remote ref` は初回 push 前として無視。他の失敗はリトライ規約）。その後 `git push --force-with-lease R HEAD:refs/heads/<branch>`。事前 fetch により「前回 push は適用されたが応答喪失」でも lease 基準が現実に追いつき、`stale info` での恒久拒否に陥らない（このブランチの writer は自分だけなので lease 基準の更新は安全）。失敗は exit 6。
8. PR（config.pr が auto で gh あり GitHub remote のとき）: `gh pr list --head <branch> --json number,baseRefName` で既存確認。既存 PR の `baseRefName != M` なら `gh pr edit <n> --base M` で矯正（失敗は警告のみ。実敗 #7 の gh 層残滓）。無ければ `gh pr create --base M --head <branch> --title "<slug>: <intent>" --body "directive d%05d / agents-kit"`。失敗は警告のみで続行。
9. WRITE-STATE: `claim.status = "ready"`、`refreshed_at = NOW`（msg = `ready <slug>`。precheck = claim 存在 ∧ agent 一致。不成立 exit 8）。
10. 出力: 「次: agents merge <slug>」。PR URL があれば併記。固定リマインド行。

### 8.6 `agents merge [<slug>] [--seen dNN] [--allow-lost-symbols "a,b" --reason "<1行>"]`

直列化された唯一の main 反映経路。slug 省略時は自 worktree の claim（**worktree 外で slug 省略は exit 2**）。merge は他セッションの ready claim に対して worktree 外からも実行できる（done 済み = branch は push 済みで、所有 worktree には触れないため安全）。番号付き手順（実装はこの順序・この境界を厳守）:

0. **run token**: `run = secrets.token_hex(3)` を生成（ロックの同一性・merge worktree 名に使う。claim の agent とは別物）。
1. **前提**: config 読込（test_cmd 必須。null は exit 3）。READ-STATE。対象 claim 存在かつ `status == "ready"` でなければ exit 3（`active` なら「先に agents done」、不在なら「claim が無い。evict/merge 済みか slug 誤り」）。**スナップショット保存**: `agent0 = claim.agent`、`branch0 = claim.branch`。以後、対象 claim への書込はすべて (agent0, branch0) との一致を precheck する（merge 実行中の evict→再claim から新所有者を守る）。
2. **directive ゲート**: 8.5 手順 4 と同一（表示順・precheck のループ内再計算・agent0/branch0 一致検査を含む。復唱成功時の `SEEN_OK = maxd` を記憶）。
3. **ロック取得**（WRITE-STATE, msg = `lock merge <slug>`）: precheck = `locks/merge.json` 不在、または stale（`NOW - acquired_at > ttl_min`）。stale なら mutate で置換し「stale ロック（<agent>/<slug>, <経過>分）を奪取した。前保持者のテストがまだ走っている可能性はあるが、安全は main push の FF 検査が守る。奪取警告が出ても手動修復は不要」と表示。非 stale で保持者ありなら exit 4「保持者 <agent>/<slug>、残 <n> 分。待って再実行」。mutate = §4.4 の内容で作成（`agent = run`）。**手順 4 以降のあらゆる失敗パス（exit 3/4/6/7 のすべて）は、必ず §8.6b の UNLOCK を経由してから exit する**（プロセス死は TTL が回収）。
4. **fetch**: fetch main + `git fetch --quiet R +refs/heads/<branch0>:refs/remotes/R/<branch0>`。`BR = git rev-parse refs/remotes/R/<branch0>`（無ければ UNLOCK、exit 3「push されていない。agents done をやり直せ」）。ローカル `refs/heads/<branch0>` が存在して BR と不一致なら UNLOCK、exit 3「未 push コミットあり。agents done をやり直せ」。`M_SHA = git rev-parse refs/remotes/R/M`。
   **4b. 既マージ検出（回収経路）**: `git merge-base --is-ancestor BR M_SHA` が真 → 前回の merge が push 成功後に死んだ等。マージ・テストを行わず回収のみ:
   - `git rev-list --first-parent --parents -n 1000 M_SHA` の出力から第 2 親が BR の行を探し、あれば `merge_commit = その行のコミット`、`main_before = その第 1 親`、`main_after = merge_commit`。無ければ 3 値とも null。
   - WRITE-STATE 1 コミット（msg = `merge-log <slug>`）: log 追加（§4.5、`recovery: true`, `branch_tip = BR`, `tests: "skipped-recovery"`）+ claim 削除（**(agent, branch) == (agent0, branch0) の場合のみ**。不一致なら削除せず「claim は別セッションが再取得済み。claim は残す」と警告）+ lock 削除（`lock.agent == run` の場合のみ）。
   - 手順 12a の lease 付きブランチ削除を実行 → 「既マージを検出し回収した: <merge_commit or 不明>」を表示して exit 0。
5. **クリーン worktree**: `WT = ROOT/<worktree_root>/merge-<run>` に `git worktree add --detach WT M_SHA`。直後に `git -C WT status --porcelain` が非空なら UNLOCK、exit 7「クリーンであるべき新規 worktree が汚れている。repo の filter/EOL 設定を疑え」（実敗 #3 ガード）。再走時は毎回ここで新規に作り直す（**再走の起点は常に手順 4**）。
6. **シミュレーション兼本マージ**: `git -C WT merge --no-ff -m "merge <slug> (d%05d): <intent>" BR`。コンフリクト → `git -C WT merge --abort`、worktree 除去、UNLOCK、exit 4「main が進んでいる。所有 worktree で agents done（rebase+テスト）をやり直してから再度 merge」。成功なら `MERGE = git -C WT rev-parse HEAD`。ローカルで検証したこのコミット**そのもの**を後で push する（検証物と反映物の同一性。実敗 #2 対策の核）。
7. **シンボル消失チェック**: §7 を `M=M_SHA, BR, RES=MERGE` で実行。違反（− allowlist）→ 一覧と §7 の抑止文言を表示、**worktree は調査用に残す**（絶対パスを表示）、UNLOCK、exit 7。
8. **ハートビート → build+test**: まず WRITE-STATE（msg = `heartbeat merge <slug>`、`on_precheck_fail="skip"`、precheck = lock 存在 ∧ `lock.agent == run`、mutate = `acquired_at = NOW`）。precheck 不成立（奪取されていた）なら「ロックは奪取されている。安全は push の FF 検査が守るので続行する」と警告して続行。次に build_cmd（設定時）→ test_cmd を cwd=WT で実行。失敗 → worktree 残置（表示）、UNLOCK、exit 6。**1 マージごとにフルテスト**（実敗 #1）。再走のたびにハートビートも再実行される（テストが TTL 超の repo でも生きたロックが stale 化しない）。
9. **push 直前の directive 再確認 → main push（最終 CAS）**:
   - READ-STATE 1 回。最大 seq > `SEEN_OK` なら: 新 directive を全文表示、worktree 除去、UNLOCK、exit 3「テスト中に新しい指示が記録された。読んで矛盾判断の上、--seen d%05d を付けて merge を再実行せよ」（フルテストという最長の窓を directive 無防備にしない。§1 決定 4(d)）。
   - `env AGENTS_MERGE_TOKEN=1 git -C WT push R HEAD:refs/heads/M`。
   - CAS 敗北（§5.3 の全パターン。`[remote rejected] (incorrect old value)` を含む）→ main が動いた（別マージ or 人間）。worktree 除去 → 再走回数 < 2 なら**手順 4 へ戻る**（新しい main に対して再マージ・再テスト。実敗 #1/#5）。上限到達 → UNLOCK、exit 5（stderr 全文表示。branch protection 等の恒久拒否もここで可視化される）。
   - その他の失敗 → worktree 残置、UNLOCK、exit 6。
10. **反映確認**: fetch main → `git merge-base --is-ancestor MERGE refs/remotes/R/M` が偽なら UNLOCK、exit 7（ブランチは消さない。実敗 #6 ガード）。真なら続行。
11. **状態確定**（WRITE-STATE 1 コミット, msg = `merge-log <slug>`。**成功経路専用**）: `log/e%05d-merge-<slug>.json` 追加（seq 採番、§4.5、`main_before=M_SHA, main_after=MERGE, branch_tip=BR`、allowlist 使用時は `allowed_lost`/`reason`）+ `claims/<slug>.json` 削除（**precheck: 現在の claim の (agent, branch) == (agent0, branch0) の場合のみ**。不一致なら削除せず「claim は merge 中に別セッションへ渡った。claim は残す」と警告）+ `locks/merge.json` 削除（**`lock.agent == run` の場合のみ**。違うなら削除せず「ロックが奪取されていた」と警告。安全性は手順 9 の FF 検査が既に担保済み）。
12. **後片付け**: (a) 遅延ブランチ削除: 手順 10 成功後のみ `git push --force-with-lease=refs/heads/<branch0>:<BR> R :refs/heads/<branch0>`。lease 拒否（= tip が BR から動いた。merge 中に done が再実行された）→ **削除せず**「branch に未マージの新コミットがある。所有者は agents done をやり直せ」と警告。他の失敗も警告のみ。ローカル `git branch -D <branch0>` は claim worktree で checkout 中なら失敗してよい（警告のみ）。(b) merge worktree を `git worktree remove WT` + `git worktree prune`。(c) 表示: 「merged: <MERGE 短縮> → <M>」「PR があれば GitHub 上で自動的に merged になる」「所有 worktree の片付け: 中身を確認し、未 push の変更が無いことを見てから git worktree remove <claim worktree>」。固定リマインド行。

補足: ロックは最適化、安全性の正体は手順 9 の FF 検査（I-SERIAL-MERGE）。UNLOCK も CAS なので、奪取と交錯しても壊れない。

### 8.6b UNLOCK（内部 op。独立した WRITE-STATE）

- msg = `unlock merge`、`on_precheck_fail="skip"`。
- precheck: `locks/merge.json` が存在 ∧ `lock.agent == run`（自分の run token）。不成立なら**何もせず**「ロックは自分のものではないため触らない」と警告して戻る（stale 奪取後の旧保持者が新保持者のロックを消す事故の防止）。
- mutate: `locks/merge.json` 削除。
- 手順 3 成功後のあらゆる失敗 exit は必ずここを経由する（成功経路のロック削除は手順 11 の複合コミットが行い、UNLOCK は呼ばれない）。

### 8.7 `agents release [<slug>] [--force]`

claim の自発的解放（成果を捨てる/作り直す時。branch と worktree は消さない）。start 途中死で残った「worktree の無い claim」の後始末にも使う（プレイブック参照）。

1. slug 省略時は自 worktree の claim（worktree 外なら exit 2）。
2. WRITE-STATE（msg = `release <slug>`）: precheck = claim 存在（無ければ exit 3）かつ `claim.agent == 自 agent` **または** `--force`（他者の claim を外すのは明示的な乗っ取り操作。PROTOCOL は「所有者が死んだと確信できる時のみ。迷ったらユーザーに確認」と規定）。mutate = claim 削除 + `log/e%05d-release-<slug>.json` 追加。
3. 出力: 「branch <branch> と worktree <path> は残っている。中身（未 push の作業）を確認し、ユーザーに報告してから片付けよ: git worktree remove / git push R :refs/heads/<branch>」。固定リマインド行。

### 8.8 `agents evict [--dry-run] [--lock-only]`

死んだセッションの掃除。どこで実行してもよい。

1. READ-STATE。stale claim（`NOW - refreshed_at > claim_ttl_hours`）と stale lock（`NOW - acquired_at > merge_lock_ttl_min`）を列挙。worktree パスがこのマシンに存在しない claim には `(worktree不在)` を付して表示する（**表示のみ**。evict 対象の判定は TTL のみ — worktree パスはマシンローカルであり、別クローンの健全な claim を誤爆させないため）。無ければ「対象なし」exit 0。
2. `--dry-run` は一覧表示のみで exit 0。`--lock-only` は stale lock だけを対象にする（sync の stale lock 警告はこちらを案内する。claim を巻き込まない）。
3. WRITE-STATE（msg = `evict N claims`）: precheck 内で staleness を**毎回再計算**し（CAS ループ中に持ち主が refresh/heartbeat したら対象から外す）、残った対象の claim ファイル・lock を削除 + `log/e%05d-evict.json` 追加。全対象が消えていたら書き込まず exit 0。
4. 出力: evict した slug/agent の一覧と「worktree と branch は残置: <paths>。**片付けはユーザーに報告し指示を得てから行え。未 push の作業が見えたら消すな**」（実敗 #3 の教訓: 他人の未コミット作業を無言で消さない）。固定リマインド行。

---

## 9. 保護ブランチへの直接 push 防止（pre-push フック全文）

install.sh が**実効フックパス**（`core.hooksPath` 設定時はそのディレクトリ、未設定時は `<COMMON_GITDIR>/hooks`）の `pre-push` に設置する。`<MAIN>` / `<STATE>` は install 時に config の値を埋め込む（config 変更後は install.sh 再実行、と出力で案内）。

マーカーブロック（**既存フックがある場合は旧ブロックを除去した上で、このブロックだけを先頭 — shebang 直後 — に前置する。末尾追記は禁止**: 既存フックの早期 `exit 0`（手書きフックのごく普通の形）や stdin 消費の下に置くとブロックが到達不能な死にコードになり、防壁が無言で失効する。単独設置時は shebang `#!/bin/sh` を先頭に、`exit 0` を末尾に付けた完全なファイルとして書く）(impl-fix: 旧規定「末尾に追記」は実測で防壁の無言失効を生んだため前置方式に改める):

```sh
# >>> agents-kit pre-push >>> (install.sh が管理。手で編集しない)
agents_kit_tmp="${GIT_DIR:-.git}/agents-kit-prepush.$$"
if ! cat > "$agents_kit_tmp"; then
  echo "agents-kit: push 一覧(stdin)を退避できないため push を拒否した。" >&2
  exit 1
fi
agents_kit_bad=""
while read -r _lr _ls agents_kit_ref _rs; do
  case "$agents_kit_ref" in
    ("refs/heads/<MAIN>")  if [ -z "${AGENTS_MERGE_TOKEN:-}" ]; then agents_kit_bad=x; fi ;;
    ("refs/heads/<STATE>") if [ -z "${AGENTS_STATE_TOKEN:-}" ]; then agents_kit_bad=x; fi ;;
  esac
done < "$agents_kit_tmp"
if [ -n "$agents_kit_bad" ]; then
  rm -f "$agents_kit_tmp"
  echo "agents-kit: 保護されたブランチへの直接 push を拒否した。これはあなたへの停止命令である。" >&2
  echo "  main に入れる唯一の方法: '.agents/bin/agents merge <slug>'（状態の変更は agents コマンドのみ）" >&2
  echo "  --no-verify や環境変数の手動設定による回避は禁止（重大な規律違反。操作は agent-state に記録され監査される）。" >&2
  exit 1
fi
exec < "$agents_kit_tmp"
rm -f "$agents_kit_tmp"
# <<< agents-kit pre-push <<<
```

- stdin（push される ref 一覧）は `${GIT_DIR:-.git}/agents-kit-prepush.$$` に**退避**してから判定し、通過時は `exec <` で後続（既存フック本体）へ**再供給**する（stdin を読む既存フックとも共存する。退避に失敗したら fail-closed で拒否）。判定の while はパイプでなく退避ファイルからのリダイレクト読みで回す（「パイプ先サブシェルの exit が親に効かない」POSIX の罠も同時に回避）。トークン参照は `${...:-}` 形式（`sh -u` な既存フック環境でも誤爆しない）。判定は if 文で書く（`[ ] &&` 形式は `sh -e` 下で偽時に errexit を誘発する）。実装はこの形を維持すること。(impl-fix)
- ブロックは通過時に `exit` しない（フォールスルー）。単独設置ファイルの `exit 0` はブロック外＝ファイル末尾の 1 行として書く（前置設計との一貫性）。
- トークンの説明コメントは意図的に書かない（変数名がコード上見えるのは判定に必要なため不可避だが、回避手順を自己文書化しない）。`agents merge` 手順 9 だけが `AGENTS_MERGE_TOKEN=1` を、WRITE-STATE と install.sh だけが `AGENTS_STATE_TOKEN=1` を子プロセス env に立てる。**どちらのトークン名もユーザー向け出力・PROTOCOL 本文には書かない**。
- `agents done` の push（`agent/*`）は対象外なのでそのまま通る。main / state の削除 push（`:refs/heads/...`）も remote_ref 一致で拒否される。
- これは同一マシン・同一クローンに対する物理防壁。別クローン・別マシンは install.sh 再実行でカバーし、組織的に固めたい場合の GitHub branch protection は**推奨設定**として PROTOCOL.md 付録に記載する（前提にはしない。設定内容は §11 章 8 の通り正確に指定する — require PR 系は非互換）。

---

## 10. install.sh 仕様

用法: `install.sh <target-repo-path> [--no-push]`（path 省略時 `.`）。bash スクリプト。**冪等**（全手順が検査後書込）。グローバル設定（`~/.claude`、`git config --global`、repo 外の hooksPath 先）には一切触れない。

1. **検証と検出**: 対象が git repo か（`git -C T rev-parse --git-dir`）。remote（既存 config があればその `remote`、無ければ `origin`）が存在するか。無ければ exit 1 で次のレシピを表示: 「共有 remote が必要。ローカル専用なら: `git init --bare ../<repo>-coord.git && git -C <repo> remote add origin ../<repo>-coord.git`（push の FF 検査はローカル bare でも同一に働く）」。**default branch 検出**: `git ls-remote --symref <remote> HEAD` の `ref: refs/heads/<name>` を読む（検出不能なら `main` にフォールバックし警告）。既存 config があればその `main_branch` が優先。**ブランチ名の検証**: `main_branch` / `state_branch` はフックと JSON に埋め込むため文字集合を `[A-Za-z0-9._/-]` に限定し、外れる名前は赤字で exit 1（シェル/sed メタ文字で防壁が無言で壊れる名前を拒否する）。(impl-fix)
2. **事前 dirty 記録**: これから触る kit 管理外ファイル（`AGENTS.md` / `CLAUDE.md` / `.gitignore` **とそれぞれの symlink 実体（repo 内の場合。realpath 解決は本手順より前＝一切の変更より前に行う）**、フック設置先が追跡ファイルの場合はそれ）について `git -C T status --porcelain -- <files>` を記録する（手順 8 の自動 push 可否判定に使う。**変更前に**取ること。字面のリンク名だけを見ると実体＝追跡ファイルの未コミット変更が素通りし、ブートストラップ push でユーザーの未公開内容が main に載る）。**ただし差分が kit 生成分のみのファイル**（内容から kit のポインタブロック / pre-push ブロック / .gitignore 追記 2 行を除いた残りが HEAD と一致。末尾改行差のみ許容）**は dirty とみなさない**（前回 run が生成した未追跡ファイルが「事前 dirty」と誤判定され、--no-push → 再実行の回復動線が永遠に push しなくなるのを防ぐ。ユーザー由来の変更は従来どおり dirty）。(impl-fix)
3. `T/.agents/bin/agents` と `T/.agents/PROTOCOL.md` をキット同梱物から**常に上書き**配置（kit 管理ファイル。実行 bit 付与）。`T/.agents/config.json` が無ければ `{"test_cmd": null, "main_branch": "<検出値>"}` で生成（`merge_lock_ttl_min` の指針コメントを併記した README 的説明を出力に含める。JSON にコメントは書けない）。**既存なら触らない**。
4. `T/AGENTS.md` と `T/CLAUDE.md` にポインタブロックを設置。マーカー `<!-- >>> agents-kit >>> -->` 〜 `<!-- <<< agents-kit <<< -->` が既にあれば置換、無ければ末尾に追記、ファイルが無ければ新規作成。**symlink 対応**: 対象が symlink なら実体パスに対して追記/置換し、リンクは保持する（tmp に書いて mv で置換する実装は symlink を実体化させるため禁止）。CLAUDE.md と AGENTS.md が互いに symlink の場合は実体側だけを 1 回処理する。本文:

   ```
   <!-- >>> agents-kit >>> (install.sh が管理。手で編集しない) -->
   この repo は複数 AI セッション並行開発の協調プロトコルを使う。
   作業を始める前に .agents/PROTOCOL.md を読み、従うこと。
   調整 CLI: .agents/bin/agents（まず: .agents/bin/agents sync）
   worktree 内で見つからない場合はリポジトリルートの .agents/bin/agents を絶対パスで実行。
   <!-- <<< agents-kit <<< -->
   ```

5. `T/.gitignore` に行 `/.worktrees/` と `/.agents/config.json` が無ければ追記（行単位の存在検査で冪等）。
6. **フック設置**（§9）: `HP = git -C T config --get core.hooksPath`。
   - HP 未設定 → 対象 = `COMMON_GITDIR/hooks/pre-push`。無ければ完全ファイルとして設置＋実行 bit。既存ファイルがあれば（自マーカーの有無を問わず）**旧ブロックを除去した上で新ブロックを先頭（shebang 直後）に前置**（§9。再 install で「shebang → exit 0 → ブロック」の到達不能な並びを作らない）。(impl-fix)
   - HP が repo 内（T 相対で解決して T 配下）→ `<HP>/pre-push` に同じ方針でブロック前置/置換（無ければ作成＋実行 bit）。設置先が**追跡ファイル**（husky の `.husky/pre-push` 等）なら手順 8 の push 対象に含める。
   - HP が repo 外（グローバル hooks 等）→ **書かない**。赤字警告と手動**前置**用ブロックを表示（先頭＝shebang 直後に置くことと、sync が毎回警告し続けることも明記）。(impl-fix)
7. **`agent-state` 初期化**: `git -C T ls-remote <remote> refs/heads/<state>` が空なら、plumbing で初期コミットを作成し push:
   `B=$(printf '0\n' | git hash-object -w --stdin)`、README も同様 → `TREE=$(printf '100644 blob %s\tcounter\n100644 blob %s\tREADME.md\n' "$B" "$R" | git mktree)` → `C=$(git -c user.name=agents-kit -c user.email=agents-kit@local commit-tree $TREE -m 'agents-kit: state root')`（**親なし** = orphan）→ `AGENTS_STATE_TOKEN=1 git push <remote> $C:refs/heads/<state>`。
   **push 失敗は §5.3 で分類**: CAS 系パターン → 誰かが先に作った＝成功扱い。それ以外（認証・接続等）→ stderr 全文を表示して exit 1（「成功」と偽らない）。最後に `ls-remote` で `refs/heads/<state>` の存在を再確認してから成功を宣言する（無限空振りループの根絶）。
8. **ブートストラップ push**（.agents 一式を main に載せる。導入デッドロックの解消。`--no-push` 時はスキップして内容確認を促し、「push は install.sh 再実行で行え」と表示）:
   a. fetch main（`refs/remotes/<remote>/<main>` 不在＝unborn は空ツリー扱い）。remote 版 `.agents/bin/agents` の blob が今回配置した実体と同一 hash なら**スキップ**（冪等。kit 更新時は差分ありとして進む）。**この判定は b（および --no-push 分岐）より先に行う**（逆順だとブートストラップ済み repo で「commit して再実行せよ」という誤った行動指示を出す）。(impl-fix)
   b. 手順 2 の事前 dirty が非空 → 自動 push せず表示して手順 9 へ: 「<files> に既存の未コミット変更があるため自動 push しない。内容を確認して commit した後、install.sh を再実行せよ（install.sh が push する）」。ユーザーの未コミット変更を黙って main に載せない（kit 生成分のみの差分は手順 2 で除外済み — kit 自身の生成物で自動 push を止め続けない）。
   c. 一時 index（`GIT_INDEX_FILE`）で `read-tree <tip>^{tree}`（unborn は `read-tree --empty`）→ 対象ファイルを add（`.agents/bin/agents`, `.agents/PROTOCOL.md`, `AGENTS.md`, `CLAUDE.md`（symlink は実体側）, `.gitignore`, 手順 6 で追記した追跡フックファイル。**config.json は含めない**＝ignore 済み・クローンローカル）→ `write-tree` → `commit-tree -p <tip>`（unborn は親なし）`-m "agents-kit: install"` → `AGENTS_MERGE_TOKEN=1 git push <remote> COMMIT:refs/heads/<main>`（トークンは内部で立てるだけで**表示しない**）。
   d. push 失敗の分類は §5.3: CAS 系 → fetch し直して c を再構築（≤5 回）。それ以外（認証・branch protection の PR 必須設定等）→ stderr 全文と手動レシピを表示して exit 1: 「ブランチを切って通常の PR/マージ手順で上記ファイルを main に入れ、その後 install.sh を再実行して検証せよ」。
   これにより、導入直後の「git push origin main が自前フックに拒否され、回避手段を初日に学習する」経路は存在しなくなる。ユーザー/AI が手で main に push する正当な場面は導入フローに一切残らない。
9. **出力**（次にやることを明示）: (a) `.agents/config.json` の `test_cmd` を設定せよ（例つき。テスト無しなら `"true"`。`merge_lock_ttl_min` はフルテスト所要時間の 2 倍以上に）。config はクローンローカル＝コミットされない。別クローンでは install.sh 再実行＋test_cmd 再設定。 (b) 各 AI セッションには「.agents/PROTOCOL.md を読め」とだけ言えばよい。 (c) 推奨: GitHub branch protection の設定内容（§11 章 8 の正確な指定を転載）。 (d) 手順 8 をスキップした場合はその理由と次アクション。

---

## 11. PROTOCOL.md の章立てと文面方針

文面方針: **AI が読んで従う前提**。(1) 命令形・1 ルール 1 行、(2) 理由は括弧書きで最大 1 行、(3) 正常系は 1 本道の番号付きコマンド列、(4) 異常系は「症状見出し → IF-THEN の手順」のプレイブック形式、(5) 曖昧語（「適宜」「なるべく」）禁止、(6) すべてのコマンドはコピペ可能な完全形で書く（例外: --seen と --allow-lost-symbols の完成形は書かない。値の読了を強制するため）。

章立てと各章の内容（条文は実装時にこの方針で書く。◆はそのまま収録する確定条文）:

1. **最初にすること** — `.agents/bin/agents sync` を実行し、この文書を最後まで読む。◆「ユーザーから指示の発言を受けたら、その発言があったターンの内に `agents directive "<発言の原文>"` で記録せよ。実装・調査・返答のどれよりも先に行え」（行動単位で書く。「作業前に記録」のような時点の曖昧な文を使わない）。
2. **鉄則（5 条）** — ◆「main へ直接 push するな。マージは `agents merge` だけが行う（フックが拒否する。拒否されたらそれは停止命令であり、回避ではなく merge コマンドに戻れ）」◆「作業は必ず `agents start` が作った自分の worktree の中で行え。主 checkout と他人の worktree に書き込むな」◆「ユーザーの指示は要約せず原文のまま `agents directive` で台帳に記録してから動け」◆「done と merge の前に必ず sync し、`!! NEW` の directive を読め。矛盾したら後の指示（seq が大きい方）が正」◆「`gh pr merge`・GitHub Web UI のマージボタン・積み PR（agent ブランチを base にした PR）は禁止」
3. **正常系フロー（1 本道）** — sync → directive → start → 実装（コミットは小さく。30 分ごと目安に worktree 内で sync）→ done → merge。各段の完全なコマンド例と期待出力。worktree 内でコマンドが見つからない時はルートの `.agents/bin/agents` を絶対パスで。
4. **異常系プレイブック** — 見出しは症状で引く:
   - 「**agents コマンドが『CAS 敗北』『リトライ上限』と言った**: 正常。自動リトライ済み。exit 5 なら少し待って再実行」（見出しを agents コマンドの発言に限定し、手打ち git push の失敗を「正常」と誤読させない）
   - 「**git push が『直接 push は禁止』『停止命令』と言った**: それはあなたへの停止命令。main へは `.agents/bin/agents merge <slug>` だけ。--no-verify や環境変数での回避は禁止」
   - 「**.agents/bin/agents が見つからない**: リポジトリルートの `.agents/bin/agents` を絶対パスで実行せよ」
   - 「**start が claim 衝突と言った**: 相手の intent を読み、待つ/分担変更/slug 変更を選ぶ。奪うな」
   - 「**新 directive が自分の作業と矛盾**: 小さな方向転換なら claim を保ったまま新 directive に従って作り直し、`done --seen` で復唱。根本から覆ったら `agents release` → 新 `start`。矛盾したまま merge するな」
   - 「**merge ロックが残っている**: sync で stale 表示なら `agents evict --dry-run` で確認してから `agents evict --lock-only`。stale でないなら待て」
   - 「**『ロックが奪取されていた/奪取した』警告**: 手動修復不要。安全は main push の FF 検査が守る。テストが長い repo なら config の merge_lock_ttl_min をテスト所要の 2 倍以上に上げよ」
   - 「**rebase コンフリクト**: worktree 内で解消 → `git add` → `git rebase --continue` → 再度 `agents done`」
   - 「**テスト失敗**: push されていない。直してから再度 done/merge」
   - 「**done の branch push が失敗した**: そのまま再度 `agents done`（push 前に fetch するので自己回復する）。繰り返すなら stderr をユーザーに報告」
   - 「**自分の claim が evict されていた（exit 8）**: 作業を止めよ。sync → 生きている directive を確認 → 新しく start からやり直し、旧 branch から必要分を取り込む。旧 claim の slug が別セッションに再claim されていても、その claim・worktree・branch に触るな」
   - 「**start が途中で死んだ（claim はあるが worktree が無い）**: 自分のターミナルの事故だと確認できた場合のみ `agents release <slug> --force`。worktree が残っていれば中身を確認してから `git worktree remove`。確信が無ければユーザーに報告」
   - 「**worktree に agents.json が無い**: `git rev-parse --absolute-git-dir` 直下に `{"slug":...,"agent":...,"branch":...}` を手書きで復元してよい（agent と slug は branch 名 `agent/<agent>/<slug>` から逆引きできる）」
   - 「**merge が途中で死んだ**: もう一度 `agents merge <slug>` を実行すれば安全（push 済みなら回収経路が後片付けだけを行う）。残った `.worktrees/merge-*` は中身を確認し、ユーザーに報告してから消す」
   - 「**worktree が汚れていると言われた**: `git status` で確認。他セッションの残骸なら触らず報告」
   - 「**長時間の離席から戻った**: 作業再開の前にまず worktree 内で `agents sync`。自分の claim が生きているか確認してから続きをせよ」
5. **後勝ちルール** — 矛盾の定義（同じ対象への両立しない指示）。seq 大が常に正。作業途中で負けた側は議論せず巻き戻す。判断に迷う組は両方の directive 番号を挙げてユーザーに 1 行で確認（確認結果も directive として記録）。
6. **禁止事項** — gh pr merge / GitHub Web UI のマージボタン / 積み PR / main・agent-state への直接 push と force push / `git push --no-verify` / フックが検査する環境変数を手で設定する行為（install.sh と agents の内部のみ例外）/ 他人の worktree・claim の操作（release --force は所有者が死んだと確信できる時のみ）/ `--seen` の偽装（実際に読んでから）/ ユーザーの明示承認なしの `--allow-lost-symbols` / agent-state ブランチの手動編集・手動 push。
7. **コマンドリファレンス** — 全サブコマンドの 1 行要約と exit code 表（§8.0 の表を転載。exit 8 = 作業停止シグナルであることを強調）。
8. **付録** — デバッグ手段（§5.4）。**GitHub branch protection 推奨設定（正確に）**: 「main と agent-state に対して有効化するのは **force push 禁止（Allow force pushes をオフ）** と **ブランチ削除禁止（Allow deletions をオフ）** の 2 つだけ。**Require a pull request before merging 系は設定しない**（agents merge の直接 push と非互換でツールが自壊する。どうしても設定する場合はユーザー自身を bypass に入れる）」。孤児の掃除: sync の孤児一覧と `git ls-remote <remote> 'refs/heads/agent/*'` で残存ブランチを確認し、ユーザーに報告してから消す。複数クローン運用時の注意（クローンごとに install.sh + config.json はクローンローカルなので test_cmd を各自設定）。config.json の変更は sync が全セッションに即時に効く（ROOT のファイルを読むため）。

---

## 12. 過去の実敗 8 件 → 仕組み対応表（BRIEF 必須要件）

| # | 実敗 | 織り込んだ仕組み（本仕様の該当箇所） |
|---|---|---|
| 1 | 別ファイル同士の意味衝突（4 回） | マージの完全直列化: merge ロック（8.6 手順 3、ハートビート付き）+ main push の FF 検査（手順 9、I-SERIAL-MERGE）。**1 マージごと**にマージ結果そのものへ build+test（手順 8、I-TEST-EACH）。意味衝突の早期警告としてパス重複の過検出（§6）と intent/interfaces の強制表示（8.2 手順 7） |
| 2 | gh pr merge が静かにコードを消す | `gh pr merge` の使用を全廃（merge はローカルマージ + 直接 push の一本道、§1 決定 7。Web UI のマージボタンも禁止）。検証したローカルマージコミット**そのもの**を push（8.6 手順 6/9）。シンボル消失チェック（§7、8.6 手順 7）で「ブランチが足したもの」「main に居てブランチが消していないもの」の消失を exit 7 で遮断 |
| 3 | 共有 worktree の未コミット残留で誤診断 | マージは毎回新規 worktree（8.6 手順 5）+ 作成直後の `git status --porcelain` 空検査（同）。done も手順 2 で dirty 拒否。evict/release は他人の worktree を消さず「ユーザーに報告し指示を得てから」を明文化（8.7/8.8）。sync が主 checkout の dirty と孤児 worktree を常時警告（8.3） |
| 4 | worktree の SHA 固定漏れ | start は fetch 直後に読んだ `refs/remotes/R/M` の SHA を `base_sha` として記録し `git worktree add -b <branch> <path> <base_sha>`（8.2 手順 4-5、I-SHA）。merge worktree も `M_SHA` 明示（8.6 手順 5） |
| 5 | mergeable 判定は単独比較で順序次第で壊れる | GitHub の mergeable を一切信用しない。1 本ずつローカルマージ→テスト→push。main が動いたら**新しい main に対して再マージ・再テスト**（8.6 手順 9 の再走ループ）。残りのブランチは merge 時にコンフリクト→「done（rebase+テスト）やり直し」へ誘導（手順 6） |
| 6 | マージ直後のブランチ削除で PR 取り残し | 削除は `git merge-base --is-ancestor MERGE origin/main` の確認**後のみ**、かつ削除 push 自体を `--force-with-lease=<ref>:<BR>` で「検証した tip のまま」に限定（8.6 手順 10→12a、I-VERIFY-THEN-DELETE）。確認失敗時はブランチを消さず exit 7、lease 拒否時も消さず警告 |
| 7 | base ブランチ削除で子 PR が迷子 | 積み PR を構造的に排除: start は base 指定を受け付けず常に origin/main SHA 起点（I-NO-STACK）。gh での手動 base 指定 PR は禁止事項（§11 章 6）。done は既存 PR の base を検証し main へ矯正（8.5 手順 8） |
| 8 | rebase 後にテストせず push | done の手順順序で構造化: rebase（手順 5）→ build+test（手順 6、失敗なら push しない）→ push（手順 7）。フラグでの省略不可（§1 決定 5） |

---

## 13. 成功基準との対応（実証フェーズの検証手順）

| 成功基準 | 本仕様での検証方法 |
|---|---|
| 同時 claim 競争 20 回で勝者ちょうど 1 人 | 同一 slug で 2 プロセス同時 `agents start` ×20。勝者 exit 0、敗者 exit 4 で相手 intent 表示。判定は claims/ に 1 ファイルのみ存在すること。**敗者が exit 6 で死なないこと**（`[remote rejected] (incorrect old value)` を含む §5.3 の全 CAS パターンがループ継続になっていることの検証を兼ねる） |
| 3 セッション並行・直列マージ・毎回テスト緑・コード消失なし | 8.6 の手順がロックと FF 検査で直列化。log/e*-merge の `main_before`/`main_after` が鎖状に連続することで直列性を事後検証できる（`recovery:true` エントリは注記付きで除外） |
| 矛盾シナリオ（D1 作業中に D2）| B が `agents directive`（seq 大）→ A の done/merge が exit 3 で停止し D2 を全文表示 → A は `--seen` 復唱後、D2 準拠で作り直し。claim.seen と log が証跡。**merge のテスト実行中に D2 を記録した場合も、手順 9 の push 直前再確認が exit 3 で止めること** |
| 死んだセッションの claim 引き継ぎ | refreshed_at を過去に置いた claim を用意 → `agents evict` → 同 slug で `agents start` が成功。worktree/branch 残置の案内が出ること。**その後、旧セッションの `agents done`/`agents sync` が exit 8 で停止し、新 claim を上書き・削除しないこと**（I-OWNER の検証） |
| 実 GitHub での PR フロー | done で PR 作成 → merge 手順 9 の push で GitHub が PR を merged 化 → 手順 10 の ancestor 確認 → 手順 12a の lease 付き遅延削除、が一連で通ること |
| 導入初日のブートストラップ | 素の repo に install.sh → 追加の手作業なしで (a) main に .agents が載り、(b) `agents start` の worktree 内に CLI が存在し、(c) `git push origin main` がフックに拒否されること。husky（core.hooksPath）導入 repo でも (c) が成立すること |
| merge 中断からの回復 | merge 手順 9 の push 成功直後にプロセスを kill → 再度 `agents merge <slug>` → 回収経路（4b）がテストを再走せずに log/claim/lock/branch を後片付けし、log に `recovery:true` と実 merge commit が残ること |

---

## 14. 実装ノート

- 定数（スクリプト先頭に集約）: `CAS_MAX=10`, `CAS_SLEEP=uniform(0.2,1.0)+0.1*attempt`, `FETCH_RETRY=5`, `FETCH_SLEEP=uniform(0.1,0.5)`, `MERGE_RESTART_MAX=2`（初回+再走 2）, `PUSH_CAS_PATTERNS`（§5.2 の 7 パターン。push 失敗分類の唯一の定義とし、WRITE-STATE / merge 手順 9 / install.sh から共用）, `RECOVERY_SCAN=1000`（4b の first-parent 走査上限）, `SYM_FILE_CAP=1_000_000` bytes, `DIRECTIVE_TAIL=10`, `REFRESH_FRACTION=claim_ttl/4`, `GH_TIMEOUT=3s`, `TEST_LOG_TAIL=50` 行（失敗表示用。実行自体はチャンク単位の無遅延 tee で流す。§8.0。(impl-fix)）, `REMINDER`（§8.0 の固定リマインド行の文字列）。
- すべての git 呼び出しは `subprocess.run([...], capture_output=..., env={**os.environ, "LC_ALL": "C", "LANG": "C"})`。トークン（`AGENTS_STATE_TOKEN` / `AGENTS_MERGE_TOKEN`）は該当 push の env にだけ足す。シェル経由は build/test の `sh -c` のみ。
- `read-tree` の引数は `<tip>^{tree}`（リテラル波括弧）。zsh 等の展開問題はスクリプト内 exec なので無関係。
- WRITE-STATE の一時 index 置き場 `COMMON_GITDIR/agents-tmp/` は初回に mkdir -p。プロセス異常終了で残ったファイルは起動時に 24h より古いものを黙って削除（軽量 GC。これ以外の自動 GC はしない。孤児 worktree は sync の一覧表示＝人間判断に委ねる）。
- 状態ブランチの肥大は許容（claim は解除で消え、directive/log は小さな JSON。剪定機能は非目標）。
- `agents` の出力で SHA は 12 桁短縮、時刻は「n 分前」形式に整形してよい（--json は生値）。
- Codex サンドボックス配慮: 書き込み先は repo 内（`.worktrees/`、`.agents/`、`.git/`）と push 先 remote のみ。`/tmp` は使わない。
- exit 8 は「作業停止シグナル」。実装では該当メッセージを stderr でなく stdout の先頭にも出す（AI がどちらを読んでも気づくように）。
- 非目標の再確認: タスクキュー自律 pickup（directive 台帳はその将来拡張に耐える構造だが実装しない）、branch protection 前提、AI 間リアルタイムメッセージング（正は常に git 上の状態）。

（以上）
