#!/bin/bash
# tests/breaker.sh — agents-kit 敵対テスト（実機ブレーカー）。
#
# 単体実行可能。mktemp -d 配下に「ローカル bare origin + 複数クローン」の sandbox を
# 自作し、SPEC §13 の検証表と、敵対レビューで見つかり修正済みの欠陥の非再発を assert する。
# 全テストが通常の PASS/FAIL（全 PASS で exit 0）。
#
# 依存: git 2.30+, python3。gh には依存しない（remote が github.com を含まないため
#       PR 経路は自動スキップされる）。
set -u

KIT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$KIT_ROOT/install.sh"
SB_ROOT="$(mktemp -d)"
echo "breaker sandbox root: $SB_ROOT"
PASS=0; FAIL=0
ok()  { echo "PASS:  $1"; PASS=$((PASS+1)); }
ng()  { echo "FAIL:  $1"; shift; while [ $# -gt 0 ]; do printf '       %s\n' "$1"; shift; done; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# sandbox ビルダー: bare origin + クローン + seed + install + test_cmd=true
#   mkrepo <name>  → echo で repo パスを返す。グローバル副作用なし。
# ---------------------------------------------------------------------------
mkrepo() {
  local name="$1" def="${2:-main}" SB="$SB_ROOT/$1"
  mkdir -p "$SB"
  git init --quiet --bare -b "$def" "$SB/origin.git"
  git clone --quiet "$SB/origin.git" "$SB/repo" 2>/dev/null
  git -C "$SB/repo" config user.name breaker
  git -C "$SB/repo" config user.email breaker@local
  mkdir -p "$SB/repo/src"
  echo "# $name" > "$SB/repo/README.md"
  printf 'def seed():\n    return 1\n' > "$SB/repo/src/app.py"
  git -C "$SB/repo" add -A >/dev/null
  git -C "$SB/repo" commit --quiet -m seed
  git -C "$SB/repo" push --quiet origin "$def" 2>/dev/null
  "$INSTALL" "$SB/repo" > "$SB/install.out" 2>&1
  git -C "$SB/repo" fetch --quiet origin "+refs/heads/$def:refs/remotes/origin/$def"
  git -C "$SB/repo" reset --quiet --hard "refs/remotes/origin/$def"
  python3 - "$SB/repo/.agents/config.json" <<'PYEOF'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); c["test_cmd"] = "true"
open(p, "w").write(json.dumps(c, indent=1, sort_keys=True) + "\n")
PYEOF
  echo "$SB/repo"
}

# state ブランチへ 1 ファイルを直接書く（テスト用の細工。plumbing で FF commit → push）。
#   state_put <repo> <path-in-state> <python-expr over obj>
state_put() {
  python3 - "$@" <<'PYEOF'
import json, os, subprocess, sys
repo, path, expr = sys.argv[1], sys.argv[2], sys.argv[3]
def g(*a, **kw):
    env = dict(os.environ, LC_ALL="C", LANG="C"); env.update(kw.pop("env_extra", {}))
    return subprocess.run(["git", "-C", repo] + list(a), capture_output=True, env=env, **kw)
g("fetch", "--quiet", "origin", "+refs/heads/agent-state:refs/remotes/origin/agent-state")
tip = g("rev-parse", "refs/remotes/origin/agent-state").stdout.decode().strip()
obj = json.loads(g("cat-file", "blob", "%s:%s" % (tip, path)).stdout.decode())
obj = eval(expr, {"obj": obj})
content = (json.dumps(obj, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode()
idx = os.path.join(repo, ".git", "tmpidx-breaker")
env = {"GIT_INDEX_FILE": idx}
g("read-tree", tip + "^{tree}", env_extra=env)
blob = g("hash-object", "-w", "--stdin", input=content, env_extra=env).stdout.decode().strip()
g("update-index", "--add", "--cacheinfo", "100644,%s,%s" % (blob, path), env_extra=env)
tree = g("write-tree", env_extra=env).stdout.decode().strip()
c = g("-c", "user.name=b", "-c", "user.email=b@l", "commit-tree", tree, "-p", tip, "-m", "breaker-edit").stdout.decode().strip()
r = g("push", "--quiet", "origin", "%s:refs/heads/agent-state" % c, env_extra={"AGENTS_STATE_TOKEN": "1"})
try: os.unlink(idx)
except OSError: pass
sys.exit(r.returncode)
PYEOF
}

# ===========================================================================
# (1) 同一 slug で 2 プロセス同時 start ×20
#     勝者 exit 0 / 敗者 exit 4 / claims に 1 ファイル / 敗者は exit 6 で死なない
#     （SPEC §13「同時 claim 競争」、§5.3 の全 CAS パターンがループ継続であることの検証）
# ===========================================================================
REPO="$(mkrepo race_same)"; AG="$REPO/.agents/bin/agents"
D="$(cd "$REPO" && "$AG" directive "race" 2>/dev/null | head -n1)"
bad=0
for i in $(seq 1 20); do
  slug="r-$i"
  (cd "$REPO" && "$AG" start "$slug" --directive "$D" --paths "p$i/**" --intent "A$i") >"$SB_ROOT/a.out" 2>&1 & p1=$!
  (cd "$REPO" && "$AG" start "$slug" --directive "$D" --paths "p$i/**" --intent "B$i") >"$SB_ROOT/b.out" 2>&1 & p2=$!
  wait $p1; rc1=$?; wait $p2; rc2=$?
  git -C "$REPO" fetch --quiet origin "+refs/heads/agent-state:refs/remotes/origin/agent-state"
  n=$(git -C "$REPO" ls-tree -r --name-only refs/remotes/origin/agent-state | grep -c "^claims/$slug.json$")
  sorted="$(printf '%s\n%s\n' "$rc1" "$rc2" | sort | tr '\n' ',')"
  # 敗者が 6 で死んでいないことを明示的に確認
  if printf '%s %s' "$rc1" "$rc2" | grep -qw 6; then bad=$((bad+1)); echo "  round $i: 敗者が exit 6 で死んだ (rc=$rc1/$rc2)"; continue; fi
  [ "$sorted" = "0,4," ] && [ "$n" = "1" ] || { bad=$((bad+1)); echo "  round $i NG: rc=$rc1/$rc2 claims=$n"; }
done
[ "$bad" -eq 0 ] && ok "(1) 同一slug同時start×20: 常に勝者1・敗者exit4・claim1・敗者はexit6にならない" \
                 || ng "(1) 同一slug同時start: $bad/20 ラウンドで不正"

# ===========================================================================
# (2) 別 slug・パス非重複で 2 プロセス同時 start → 両方成功（CAS 再評価で両 claim 残存）
# ===========================================================================
REPO="$(mkrepo race_diff)"; AG="$REPO/.agents/bin/agents"
D="$(cd "$REPO" && "$AG" directive "race2" 2>/dev/null | head -n1)"
bad=0
for i in 1 2 3 4 5; do
  (cd "$REPO" && "$AG" start "l-$i" --directive "$D" --paths "l$i/**" --intent "L$i") >/dev/null 2>&1 & p1=$!
  (cd "$REPO" && "$AG" start "r-$i" --directive "$D" --paths "r$i/**" --intent "R$i") >/dev/null 2>&1 & p2=$!
  wait $p1; rc1=$?; wait $p2; rc2=$?
  git -C "$REPO" fetch --quiet origin "+refs/heads/agent-state:refs/remotes/origin/agent-state"
  nl=$(git -C "$REPO" ls-tree -r --name-only refs/remotes/origin/agent-state | grep -c "^claims/l-$i.json$")
  nr=$(git -C "$REPO" ls-tree -r --name-only refs/remotes/origin/agent-state | grep -c "^claims/r-$i.json$")
  [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && [ "$nl" = 1 ] && [ "$nr" = 1 ] || { bad=$((bad+1)); echo "  round $i NG: rc=$rc1/$rc2 claims=$nl/$nr"; }
done
[ "$bad" -eq 0 ] && ok "(2) 別slug非重複の同時start×5: 両方成功・両claim残存" \
                 || ng "(2) 別slug同時start: $bad/5 ラウンドで不正"

# ===========================================================================
# (5) evict → 同 slug 再 claim → ゾンビ（旧 worktree）の sync/done が exit 8 で止まり
#     新 claim を壊さない（I-OWNER / SPEC §13「死んだセッションの claim 引き継ぎ」）
# ===========================================================================
REPO="$(mkrepo zombie)"; AG="$REPO/.agents/bin/agents"
ST=refs/remotes/origin/agent-state
D="$(cd "$REPO" && "$AG" directive "zombie" 2>/dev/null | head -n1)"
(cd "$REPO" && "$AG" start feat-z --directive "$D" --paths "z/**" --intent "old") >/dev/null 2>&1
WT="$(ls -d "$REPO/.worktrees"/feat-z-* | head -n1)"
mkdir -p "$WT/z" && printf 'def old():\n    return 0\n' > "$WT/z/z.py"
git -C "$WT" add -A >/dev/null && git -C "$WT" commit --quiet -m old
state_put "$REPO" claims/feat-z.json 'dict(obj, refreshed_at="2000-01-01T00:00:00Z")'  # stale 化
(cd "$REPO" && "$AG" evict) >/dev/null 2>&1
(cd "$REPO" && "$AG" start feat-z --directive "$D" --paths "z/**" --intent "new") >"$SB_ROOT/restart.out" 2>&1
restart_rc=$?
git -C "$REPO" fetch --quiet origin "+refs/heads/agent-state:refs/remotes/origin/agent-state"
new_agent="$(git -C "$REPO" cat-file blob "$ST:claims/feat-z.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["agent"])')"
claim_before="$(git -C "$REPO" cat-file blob "$ST:claims/feat-z.json" | shasum | cut -d' ' -f1)"
(cd "$WT" && "$AG" sync) >/dev/null 2>&1; zsync=$?
(cd "$WT" && "$AG" done) >/dev/null 2>&1; zdone=$?
git -C "$REPO" fetch --quiet origin "+refs/heads/agent-state:refs/remotes/origin/agent-state"
claim_after="$(git -C "$REPO" cat-file blob "$ST:claims/feat-z.json" | shasum | cut -d' ' -f1)"
new_agent2="$(git -C "$REPO" cat-file blob "$ST:claims/feat-z.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["agent"])')"
if [ "$restart_rc" = 0 ] && [ "$zsync" = 8 ] && [ "$zdone" = 8 ] \
   && [ "$claim_before" = "$claim_after" ] && [ "$new_agent" = "$new_agent2" ]; then
  ok "(5) evict→再claim→ゾンビのsync/doneがexit8・新claim無傷"
else
  ng "(5) ゾンビ隔離が不正" "restart=$restart_rc zsync=$zsync(want8) zdone=$zdone(want8)" \
     "claim改変: $([ "$claim_before" = "$claim_after" ] && echo no || echo YES)"
fi

# ===========================================================================
# (4') stale ロック奪取: ttl_min=0 相当のロックを植えて merge → 奪取警告つきで安全収束
#     （SPEC §13/復C5。奪取後も 1 件が正しく main に載り、lock/claim が後始末される）
# ===========================================================================
REPO="$(mkrepo takeover)"; AG="$REPO/.agents/bin/agents"
D="$(cd "$REPO" && "$AG" directive "takeover" 2>/dev/null | head -n1)"
(cd "$REPO" && "$AG" start feat-t --directive "$D" --paths "t/**" --intent "t") >/dev/null 2>&1
WT="$(ls -d "$REPO/.worktrees"/feat-t-* | head -n1)"
mkdir -p "$WT/t" && printf 'def t():\n    return 1\n' > "$WT/t/t.py"
git -C "$WT" add -A >/dev/null && git -C "$WT" commit --quiet -m t
(cd "$WT" && "$AG" done --seen "$D") >/dev/null 2>&1
# 別 run token の生きたロックを植える（誰かが merge 中に死んだ状態）。ttl=0 なので即 stale。
python3 - "$REPO" <<'PYEOF'
import json, os, subprocess, sys
repo = sys.argv[1]
def g(*a, **kw):
    env = dict(os.environ, LC_ALL="C", LANG="C"); env.update(kw.pop("env_extra", {}))
    return subprocess.run(["git", "-C", repo] + list(a), capture_output=True, env=env, **kw)
g("fetch", "--quiet", "origin", "+refs/heads/agent-state:refs/remotes/origin/agent-state")
tip = g("rev-parse", "refs/remotes/origin/agent-state").stdout.decode().strip()
lock = {"acquired_at": "2000-01-01T00:00:00Z", "agent": "deadbe", "slug": "feat-t", "ttl_min": 0}
content = (json.dumps(lock, ensure_ascii=False, indent=1, sort_keys=True) + "\n").encode()
idx = os.path.join(repo, ".git", "tmpidx-lock"); env = {"GIT_INDEX_FILE": idx}
g("read-tree", tip + "^{tree}", env_extra=env)
blob = g("hash-object", "-w", "--stdin", input=content, env_extra=env).stdout.decode().strip()
g("update-index", "--add", "--cacheinfo", "100644,%s,locks/merge.json" % blob, env_extra=env)
tree = g("write-tree", env_extra=env).stdout.decode().strip()
c = g("-c", "user.name=b", "-c", "user.email=b@l", "commit-tree", tree, "-p", tip, "-m", "plant lock").stdout.decode().strip()
sys.exit(g("push", "--quiet", "origin", "%s:refs/heads/agent-state" % c, env_extra={"AGENTS_STATE_TOKEN": "1"}).returncode)
PYEOF
(cd "$WT" && "$AG" merge feat-t) > "$SB_ROOT/takeover.out" 2>&1; mrc=$?
git -C "$REPO" fetch --quiet origin "+refs/heads/main:refs/remotes/origin/main" "+refs/heads/agent-state:refs/remotes/origin/agent-state"
on_main=$(git -C "$REPO" ls-tree -r --name-only refs/remotes/origin/main | grep -c '^t/t.py$')
lock_left=$(git -C "$REPO" ls-tree -r --name-only refs/remotes/origin/agent-state | grep -c '^locks/merge.json$')
claim_left=$(git -C "$REPO" ls-tree -r --name-only refs/remotes/origin/agent-state | grep -c '^claims/feat-t.json$')
if [ "$mrc" = 0 ] && grep -q "奪取した" "$SB_ROOT/takeover.out" \
   && [ "$on_main" = 1 ] && [ "$lock_left" = 0 ] && [ "$claim_left" = 0 ]; then
  ok "(4) stale ロック奪取: 奪取警告つきで merge が収束・lock/claim後始末"
else
  ng "(4) stale ロック奪取が不正" "rc=$mrc on_main=$on_main lock_left=$lock_left claim_left=$claim_left" \
     "$(tail -3 "$SB_ROOT/takeover.out")"
fi

# ===========================================================================
# (7) default branch が master の repo → config 検出とフック保護対象が master
# ===========================================================================
REPO="$(mkrepo master_def master)"; AG="$REPO/.agents/bin/agents"
cfg_main="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["main_branch"])' "$REPO/.agents/config.json")"
hook_guards_master=1
grep -q 'refs/heads/master' "$REPO/.git/hooks/pre-push" || hook_guards_master=0
# master への直接 push が拒否されること
git -C "$REPO" fetch --quiet origin && git -C "$REPO" reset --quiet --hard origin/master
echo x >> "$REPO/README.md"; git -C "$REPO" add -A; git -C "$REPO" commit --quiet -m d
git -C "$REPO" push origin master >/dev/null 2>"$SB_ROOT/mpush.err"; mpush=$?
git -C "$REPO" reset --quiet --hard origin/master
if [ "$cfg_main" = master ] && [ "$hook_guards_master" = 1 ] && [ "$mpush" != 0 ] \
   && grep -q "停止命令" "$SB_ROOT/mpush.err"; then
  ok "(7) master既定repo: config=master・フックがmasterを保護・直push拒否"
else
  ng "(7) master既定の検出/保護が不正" "cfg_main=$cfg_main hook_master=$hook_guards_master push_rc=$mpush"
fi

# ===========================================================================
# (8) AGENTS.md に未コミット変更がある状態で install → 自動 push されず案内が出る
# ===========================================================================
SB="$SB_ROOT/dirty_agents"; mkdir -p "$SB"
git init --quiet --bare -b main "$SB/origin.git"
git clone --quiet "$SB/origin.git" "$SB/repo" 2>/dev/null
git -C "$SB/repo" config user.name b; git -C "$SB/repo" config user.email b@l
echo "# r" > "$SB/repo/README.md"; echo "doc v1" > "$SB/repo/AGENTS.md"
git -C "$SB/repo" add -A >/dev/null && git -C "$SB/repo" commit --quiet -m seed && git -C "$SB/repo" push --quiet origin main
echo "uncommitted" >> "$SB/repo/AGENTS.md"      # 未コミット変更
"$INSTALL" "$SB/repo" > "$SB/install.out" 2>&1
git -C "$SB/repo" fetch --quiet origin
pushed=$(git -C "$SB/repo" ls-tree -r --name-only origin/main | grep -c '.agents/bin/agents')
if grep -q "自動 push しない" "$SB/install.out" && [ "$pushed" = 0 ] \
   && grep -q "uncommitted" "$SB/repo/AGENTS.md" && grep -q "agents-kit" "$SB/repo/AGENTS.md"; then
  ok "(8) 未コミットAGENTS.md: 自動pushせず案内・ユーザー編集を保持しつつポインタ追記"
else
  ng "(8) 未コミットAGENTS.md の扱いが不正" "pushed=$pushed(want0)" "$(grep -c 自動 "$SB/install.out") 件の案内"
fi

# ===========================================================================
# (9) rebase コンフリクト → done exit 6 → 解消 → done 再実行で通る
# ===========================================================================
REPO="$(mkrepo rebase_conf)"; AG="$REPO/.agents/bin/agents"
D="$(cd "$REPO" && "$AG" directive "conflict" 2>/dev/null | head -n1)"
(cd "$REPO" && "$AG" start feat-r --directive "$D" --paths "src/app.py" --intent "r") >/dev/null 2>&1
WT="$(ls -d "$REPO/.worktrees"/feat-r-* | head -n1)"
# 外部（フック無しクローン）から main の同じ行を進める
git clone --quiet "$SB_ROOT/rebase_conf/origin.git" "$SB_ROOT/rebase_conf/other" 2>/dev/null
git -C "$SB_ROOT/rebase_conf/other" config user.name o; git -C "$SB_ROOT/rebase_conf/other" config user.email o@l
printf 'def seed():\n    return 100\n' > "$SB_ROOT/rebase_conf/other/src/app.py"
git -C "$SB_ROOT/rebase_conf/other" add -A >/dev/null && git -C "$SB_ROOT/rebase_conf/other" commit --quiet -m other
git -C "$SB_ROOT/rebase_conf/other" push --quiet origin main
printf 'def seed():\n    return 200\n' > "$WT/src/app.py"
git -C "$WT" add -A >/dev/null && git -C "$WT" commit --quiet -m mine
(cd "$WT" && "$AG" done --seen "$D") >/dev/null 2>&1; done1=$?
printf 'def seed():\n    return 300\n' > "$WT/src/app.py"
git -C "$WT" add src/app.py
GIT_EDITOR=true git -C "$WT" rebase --continue >/dev/null 2>&1
(cd "$WT" && "$AG" done --seen "$D") >/dev/null 2>&1; done2=$?
[ "$done1" = 6 ] && [ "$done2" = 0 ] \
  && ok "(9) rebaseコンフリクト: done#1 exit6 → 解消 → done#2 exit0" \
  || ng "(9) rebase フローが不正" "done1=$done1(want6) done2=$done2(want0)"

# ===========================================================================
# (10) 既存 pre-push フックが末尾 exit 0 / stdin 読みでも防壁が効く（前置＋stdin 再供給）
#   - main 直 push は拒否される（ブロックが shebang 直後に前置され到達可能）
#   - 許可される push（agent/*）では既存フック本体も走り、stdin（ref 一覧）を受け取れる
#   （修正済み欠陥の非再発: 旧「末尾追記」は早期 exit の下で防壁が無言失効した）
# ===========================================================================
SB="$SB_ROOT/hook_exit0"; mkdir -p "$SB"
git init --quiet --bare -b main "$SB/origin.git"
git clone --quiet "$SB/origin.git" "$SB/repo" 2>/dev/null
git -C "$SB/repo" config user.name b; git -C "$SB/repo" config user.email b@l
echo hi > "$SB/repo/README.md"; git -C "$SB/repo" add -A >/dev/null && git -C "$SB/repo" commit --quiet -m seed
git -C "$SB/repo" push --quiet origin main
# 末尾 exit 0 + stdin 読み（先食い）という敵対的な既存フック
printf '#!/bin/sh\nwhile read -r l s r x; do echo "own-hook saw $r" >> own-hook.log; done\nexit 0\n' > "$SB/repo/.git/hooks/pre-push"
chmod +x "$SB/repo/.git/hooks/pre-push"
"$INSTALL" "$SB/repo" >/dev/null 2>&1
git -C "$SB/repo" fetch --quiet origin && git -C "$SB/repo" reset --quiet --hard origin/main
echo evil >> "$SB/repo/README.md"; git -C "$SB/repo" add -A; git -C "$SB/repo" commit --quiet -m evil
git -C "$SB/repo" push origin main >/dev/null 2>"$SB/perr"; direct_rc=$?
git -C "$SB/repo" reset --quiet --hard origin/main
if [ "$direct_rc" != 0 ] && grep -q "停止命令" "$SB/perr"; then
  ok "(10a) 末尾exit0+stdin読みの既存フックでも main 直push が防壁に拒否される"
else
  ng "(10a) 直push が素通り/文言なし (rc=$direct_rc)" "$(cat "$SB/perr")" \
     "$(cat "$SB/repo/.git/hooks/pre-push")"
fi
git -C "$SB/repo" branch --quiet feat-x
rm -f "$SB/repo/own-hook.log"
git -C "$SB/repo" push origin feat-x >/dev/null 2>&1; feat_rc=$?
if [ "$feat_rc" = 0 ] && grep -q "refs/heads/feat-x" "$SB/repo/own-hook.log" 2>/dev/null; then
  ok "(10b) 許可pushは通り、既存フック本体にも stdin が再供給される（共存）"
else
  ng "(10b) 共存が壊れた" "feat_rc=$feat_rc own-hook.log=$(cat "$SB/repo/own-hook.log" 2>/dev/null)"
fi

# ===========================================================================
# (11) 防壁の実効性検査: 健全なら sync は警告せず、人為的に殺す（ブロック前に exit 0 を
#      挿入）と「防壁が無い/不整合」を警告する（文字列存在だけの検査では検知できなかった欠陥）
# ===========================================================================
python3 - "$SB/repo/.agents/config.json" <<'PYEOF'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); c["test_cmd"] = "true"
open(p, "w").write(json.dumps(c, indent=1, sort_keys=True) + "\n")
PYEOF
(cd "$SB/repo" && "$SB/repo/.agents/bin/agents" sync) > "$SB/sync-ok.out" 2>&1
if grep -q "防壁" "$SB/sync-ok.out"; then
  ng "(11a) 健全な防壁なのに sync が警告した" "$(grep 防壁 "$SB/sync-ok.out")"
else
  ok "(11a) 健全な防壁では sync は警告しない"
fi
python3 - "$SB/repo/.git/hooks/pre-push" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
lines.insert(1, "exit 0")   # shebang 直後に exit 0 → ブロックを到達不能にする
open(p, "w").write("\n".join(lines))
PYEOF
(cd "$SB/repo" && "$SB/repo/.agents/bin/agents" sync) > "$SB/sync-dead.out" 2>&1
if grep -q "防壁" "$SB/sync-dead.out"; then
  ok "(11b) 到達不能な防壁を sync が検知して警告する"
else
  ng "(11b) 死んだ防壁を健全と誤報告" "$(tail -n 10 "$SB/sync-dead.out")"
fi

# ===========================================================================
# (12) 同一クローンでの install.sh 再実行後も防壁が生きている（置換の冪等性。
#      旧実装は再実行で「shebang → exit 0 → ブロック」となり防壁が無言で死んだ）
# ===========================================================================
REPO="$(mkrepo reinstall)"
"$INSTALL" "$REPO" > "$SB_ROOT/reinstall/install2.out" 2>&1; rc2=$?
git -C "$REPO" fetch --quiet origin && git -C "$REPO" reset --quiet --hard origin/main
echo evil >> "$REPO/README.md"; git -C "$REPO" add -A; git -C "$REPO" commit --quiet -m evil
git -C "$REPO" push origin main >/dev/null 2>"$SB_ROOT/reinstall/perr"; rp=$?
git -C "$REPO" reset --quiet --hard origin/main
nblk="$(grep -cF '>>> agents-kit pre-push >>>' "$REPO/.git/hooks/pre-push")"
if [ "$rc2" = 0 ] && [ "$rp" != 0 ] && grep -q "停止命令" "$SB_ROOT/reinstall/perr" && [ "$nblk" = 1 ]; then
  ok "(12) 再install後も直pushが拒否される（ブロックは1個のまま）"
else
  ng "(12) 再installで防壁が死んだ/重複した" "rc2=$rc2 push_rc=$rp blocks=$nblk" \
     "$(cat "$REPO/.git/hooks/pre-push")"
fi

# ===========================================================================
# (13) --no-push → 内容確認 → 再実行で push される（回復動線。旧実装は自分の生成物を
#      「事前 dirty」と誤判定して永遠に push しなかった）
# ===========================================================================
SB="$SB_ROOT/nopush"; mkdir -p "$SB"
git init --quiet --bare -b main "$SB/origin.git"
git clone --quiet "$SB/origin.git" "$SB/repo" 2>/dev/null
git -C "$SB/repo" config user.name b; git -C "$SB/repo" config user.email b@l
echo "# r" > "$SB/repo/README.md"
git -C "$SB/repo" add -A >/dev/null && git -C "$SB/repo" commit --quiet -m seed && git -C "$SB/repo" push --quiet origin main
"$INSTALL" "$SB/repo" --no-push > "$SB/install1.out" 2>&1
git -C "$SB/repo" fetch --quiet origin
p1=$(git -C "$SB/repo" ls-tree -r --name-only origin/main | grep -c '^.agents/bin/agents$')
"$INSTALL" "$SB/repo" > "$SB/install2.out" 2>&1
git -C "$SB/repo" fetch --quiet origin
p2=$(git -C "$SB/repo" ls-tree -r --name-only origin/main | grep -c '^.agents/bin/agents$')
if [ "$p1" = 0 ] && [ "$p2" = 1 ] && grep -q "ブートストラップ push: 完了" "$SB/install2.out"; then
  ok "(13) --no-push→再実行でブートストラップが push される"
else
  ng "(13) --no-push の回復動線が塞がっている" "p1=$p1(want0) p2=$p2(want1)" \
     "$(grep -A3 'push' "$SB/install2.out" | head -n 8)"
fi

# ===========================================================================
# (14) AGENTS.md が repo 内追跡ファイルへの symlink で、実体に未コミット変更がある →
#      自動 push せず案内（旧実装は字面の AGENTS.md しか見ず、実体の未公開内容が main に載った）
# ===========================================================================
SB="$SB_ROOT/symdirty"; mkdir -p "$SB"
git init --quiet --bare -b main "$SB/origin.git"
git clone --quiet "$SB/origin.git" "$SB/repo" 2>/dev/null
git -C "$SB/repo" config user.name b; git -C "$SB/repo" config user.email b@l
mkdir -p "$SB/repo/docs"
echo "# r" > "$SB/repo/README.md"; echo "agents doc" > "$SB/repo/docs/agents.md"
ln -s docs/agents.md "$SB/repo/AGENTS.md"
git -C "$SB/repo" add -A >/dev/null && git -C "$SB/repo" commit --quiet -m seed && git -C "$SB/repo" push --quiet origin main
echo "SECRET WIP: do not publish" >> "$SB/repo/docs/agents.md"   # 実体側の未コミット変更
"$INSTALL" "$SB/repo" > "$SB/install.out" 2>&1
git -C "$SB/repo" fetch --quiet origin
pushed=$(git -C "$SB/repo" ls-tree -r --name-only origin/main | grep -c '^.agents/bin/agents$')
leaked=$(git -C "$SB/repo" cat-file blob origin/main:docs/agents.md 2>/dev/null | grep -c "SECRET WIP")
if grep -q "自動 push しない" "$SB/install.out" && [ "$pushed" = 0 ] && [ "$leaked" = 0 ]; then
  ok "(14) symlink実体の未コミット変更: 自動pushせず、未公開内容がmainに載らない"
else
  ng "(14) symlink実体のdirtyが素通り" "pushed=$pushed(want0) leaked=$leaked(want0)" \
     "$(grep -B1 -A4 'push' "$SB/install.out" | head -n 10)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "==== breaker 結果: PASS=$PASS FAIL=$FAIL ===="
if [ "$FAIL" -eq 0 ]; then
  echo "全 PASS。"
  rm -rf "$SB_ROOT"
  exit 0
else
  echo "sandbox を残した（調査用）: $SB_ROOT"
  exit 1
fi
