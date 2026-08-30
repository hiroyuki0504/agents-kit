#!/bin/bash
# demo.sh — agents-kit を 1 コマンドで体験する自己完結デモ。
# https://github.com/hiroyuki0504/agents-kit (MIT License)
#
# mktemp -d 配下にローカル bare origin + クローンの sandbox を作り、実物の
# install.sh と .agents/bin/agents だけ（モックなし）で次の物語を最後まで実演する:
#   2 つの AI セッションが同じタスクを取り合い（勝者はちょうど 1 人）、途中で
#   ユーザーの気が変わり（後勝ち）、未読 directive ゲートに止められた側が作り直して
#   直列マージ（1 マージごと全テスト）で main に入れる。
# ネットワーク・GitHub・AI・追加依存は不要（git 2.30+ / python3 / sh のみ）。
# 各段は exit code と出力要点をアサートし、ズレたら FAIL を出して非 0 で落ちる
# （CI でそのまま回せる）。全段成功で緑のまとめと exit 0。実行時間の目安は数十秒。
# ナレーションは英語、CLI 実出力は日本語のまま表示する（読者への断りは冒頭に出す）。
#
# 実行: bash demo.sh   （どのカレントディレクトリから叩いてもよい。
#                        install.sh はこのスクリプト自身の位置から見つける）
set -u

# ---------------------------------------------------------------------------
# 前提確認と自己位置の解決（カレント非依存）
# ---------------------------------------------------------------------------
for dep in git python3; do
  command -v "${dep}" >/dev/null 2>&1 || {
    echo "demo.sh: missing dependency: ${dep} (see Requirements in README.md / README.ja.md の「動作環境」)" >&2
    exit 1
  }
done
KIT_ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL="${KIT_ROOT}/install.sh"
[ -f "${INSTALL}" ] || {
  echo "demo.sh: ${INSTALL} not found — run demo.sh from a full checkout of agents-kit" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# sandbox（trap で必ず後片付け）と git 環境の隔離
# ---------------------------------------------------------------------------
SB="$(mktemp -d)" || exit 1
trap 'rm -rf "${SB}"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 第三者の環境で確実に再現させるため、グローバル git 設定（gpgsign / hooksPath /
# init.defaultBranch 等）と紛れ込んだ環境変数から sandbox を隔離する。
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_NAMESPACE GIT_CEILING_DIRECTORIES
unset AGENTS_MERGE_TOKEN AGENTS_STATE_TOKEN
export GIT_CONFIG_NOSYSTEM=1
export HOME="${SB}/home"
export XDG_CONFIG_HOME="${SB}/home/.config"
mkdir -p "${HOME}"

# ---------------------------------------------------------------------------
# 表示・アサートの部品
# ---------------------------------------------------------------------------
C_B=$'\033[1m'; C_C=$'\033[36m'; C_G=$'\033[32m'; C_R=$'\033[31m'; C_0=$'\033[0m'
LOG="${SB}/last-output.log"
: > "${LOG}"
RC=0
CHECKS=0

say() { printf '%s\n' "$*"; }

stage() {  # stage <n> <title> [explanation lines...]
  local n="$1" t="$2" l
  shift 2
  printf '\n%s\n' "${C_B}== [${n}/7] ${t} ==${C_0}"
  for l in "$@"; do
    printf '   %s\n' "${l}"
  done
}

act() {  # act <who> <what> — コマンド以外の行動のナレーション
  printf '%s\n' "${C_C}[$1] $2${C_0}"
}

demo_run() {  # demo_run <who> <cwd> <pretty-cmdline> <argv...> — 実行し、実出力を | 付きで表示
  local who="$1" cwd="$2" label="$3"
  shift 3
  printf '%s\n' "${C_C}[${who}] \$ ${label}${C_0}"
  ( cd "${cwd}" && "$@" ) > "${LOG}" 2>&1
  RC=$?
  sed 's/^/  | /' "${LOG}"
}

fail() {
  printf '%s\n' "${C_R}FAIL: $1${C_0}" >&2
  if [ -s "${LOG}" ]; then
    printf '%s\n' "---- last captured command output ----" >&2
    sed 's/^/  | /' "${LOG}" >&2
  fi
  printf '%s\n' "demo aborted after ${CHECKS} passing check(s). Sandbox is removed by trap." >&2
  exit 1
}

pass() { CHECKS=$((CHECKS+1)); printf '%s\n' "  ${C_G}PASS:${C_0} $1"; }
expect_rc()  { [ "${RC}" -eq "$1" ] || fail "$2 — expected exit $1, got ${RC}"; }
expect_out() { grep -qF -- "$1" "${LOG}" || fail "$2 — output should contain: $1"; }
first_line() { head -n1 "${LOG}"; }

# ---------------------------------------------------------------------------
# イントロと種 repo（bare origin + クローン + seed コミット）
# ---------------------------------------------------------------------------
say "${C_B}agents-kit demo — two AI sessions, one repo, no conflicts${C_0}"
say "This script builds a throwaway sandbox (a local bare origin + one clone) under mktemp,"
say "then replays a full multi-session story using the real install.sh and the real"
say ".agents/bin/agents CLI: a claim race, a user who changes their mind mid-flight, the"
say "unseen-directive gate, and one serialized, fully-tested merge into main."
say "No network, no GitHub, no AI involved — just git + python3 + sh."
say "NOTE: CLI output is in Japanese by design — the primary readers are AI agents. Watch the exit codes and the narration."
say ""
say "sandbox: ${SB} (removed automatically on exit)"

git init --quiet --bare -b main "${SB}/origin.git" \
  || fail "could not create the bare origin (git 2.30+ required)"
git clone --quiet "${SB}/origin.git" "${SB}/repo" 2>/dev/null \
  || fail "could not clone the sandbox origin"
git -C "${SB}/repo" config user.name "agents-kit-demo" \
  && git -C "${SB}/repo" config user.email "demo@local" \
  && git -C "${SB}/repo" config commit.gpgsign false \
  || fail "could not configure the sandbox clone"
printf '# demo-app\n\nA tiny app that two AI sessions will build together.\n' > "${SB}/repo/README.md"
cat > "${SB}/repo/test.sh" <<'EOF'
#!/bin/sh
# demo-app test runner (dependency-free): run every tests/*.sh from the repo root.
set -e
cd "$(dirname "$0")"
for t in tests/*.sh; do
  [ -f "$t" ] || continue
  sh "$t"
done
echo "test.sh: all tests passed"
EOF
git -C "${SB}/repo" add -A >/dev/null \
  && git -C "${SB}/repo" commit --quiet -m "seed: README + dependency-free test runner" \
  && git -C "${SB}/repo" push --quiet origin main \
  || fail "could not seed the sandbox repo"
say "seeded: demo-app (README.md + test.sh) pushed to the sandbox origin"

# ---------------------------------------------------------------------------
# [1/7] 導入
# ---------------------------------------------------------------------------
stage 1 "Install the kit — one command, and origin gets a coordination ledger" \
  "install.sh puts .agents/ into the repo, creates the orphan agent-state ledger branch on" \
  "origin, installs a pre-push barrier for main, and auto-pushes the kit to main (bootstrap)."
demo_run "operator" "${KIT_ROOT}" "./install.sh \"\${SANDBOX}/repo\"" "${INSTALL}" "${SB}/repo"
expect_rc 0 "install.sh should succeed"
expect_out "agents-kit 導入完了" "install.sh should report completion"
expect_out "ブートストラップ push: 完了" "install.sh should bootstrap-push .agents to origin/main"
[ -n "$(git -C "${SB}/repo" ls-remote origin refs/heads/agent-state)" ] \
  || fail "origin should now have the agent-state ledger branch"
AG="${SB}/repo/.agents/bin/agents"
[ -x "${AG}" ] || fail ".agents/bin/agents should be installed and executable"
pass "installed: ledger branch on origin, kit auto-pushed to main, CLI at .agents/bin/agents"

act "operator" 'sets test_cmd to "sh test.sh" in .agents/config.json (the one manual step)'
python3 - "${SB}/repo/.agents/config.json" <<'EOF' || fail "could not set test_cmd in config.json"
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
cfg["test_cmd"] = "sh test.sh"
open(p, "w").write(json.dumps(cfg, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
EOF
grep -qF '"test_cmd": "sh test.sh"' "${SB}/repo/.agents/config.json" \
  || fail "test_cmd was not written to config.json"
pass 'test_cmd = "sh test.sh" — from now on every done/merge must run this suite green'

# ---------------------------------------------------------------------------
# [2/7] Session A: directive 記録 → claim
# ---------------------------------------------------------------------------
stage 2 "Session A: record the user's instruction verbatim, then claim the task" \
  "Rule one: an instruction goes into the ledger before any work — it becomes d00001. Then" \
  "agents start claims slug \"greet\" atomically and creates a worktree pinned to origin/main."
demo_run "Session A @ repo" "${SB}/repo" 'agents directive "Implement greet that prints Hello"' \
  "${AG}" directive "Implement greet that prints Hello"
expect_rc 0 "recording the directive should succeed"
[ "$(first_line)" = "d00001" ] || fail "the first directive should be numbered d00001 (got: $(first_line))"
pass "the instruction is in the ledger as d00001"

demo_run "Session A @ repo" "${SB}/repo" \
  'agents start greet --directive d00001 --paths "greet.sh,tests/**" --intent "implement greet"' \
  "${AG}" start greet --directive d00001 --paths "greet.sh,tests/**" --intent "implement greet"
expect_rc 0 "agents start should succeed for Session A"
expect_out "claim 完了: greet" "start should confirm the claim"
WT_A="$(ls -d "${SB}/repo/.worktrees/"greet-* 2>/dev/null | head -n1)"
[ -n "${WT_A}" ] && [ -d "${WT_A}" ] || fail "Session A should now own a worktree under .worktrees/"
WT_A_NAME="${WT_A##*/}"
pass "Session A holds the claim and got its own worktree: .worktrees/${WT_A_NAME}"

# ---------------------------------------------------------------------------
# [3/7] Session B: 同じ slug を start → 拒否（claim のアトミック性）
# ---------------------------------------------------------------------------
stage 3 "Session B claims the same task — the claim is atomic, exactly one wins" \
  "The ledger lives on origin and git push's fast-forward check acts as compare-and-swap, so" \
  "a second claim of the same slug must fail with exit code 4 and show the owner's intent."
demo_run "Session B @ repo" "${SB}/repo" \
  'agents start greet --directive d00001 --paths "greet.sh,tests/**" --intent "implement greet too"' \
  "${AG}" start greet --directive d00001 --paths "greet.sh,tests/**" --intent "implement greet too"
expect_rc 4 "the second claim of the same slug should be rejected"
expect_out "slug greet は使用中" "the rejection should say the slug is taken"
expect_out "intent=implement greet paths=" "the rejection should show the owner's intent"
[ "$(ls -d "${SB}/repo/.worktrees/"greet-* | wc -l | tr -d ' ')" = "1" ] \
  || fail "exactly one greet worktree should exist"
pass "exactly one winner — B got exit 4 with the owner's intent, and no state was touched"
say "   Session B backs off: it would pick another task or wait (nothing to clean up)."

# ---------------------------------------------------------------------------
# [4/7] Session A が Hello 仕様で実装
# ---------------------------------------------------------------------------
stage 4 "Session A implements the Hello spec (d00001) in its own worktree" \
  "Work happens only inside the claimed worktree, never in the main checkout. A writes" \
  "greet.sh plus a test, commits, and runs the suite locally — green on the Hello spec."
cat > "${WT_A}/greet.sh" <<'EOF'
#!/bin/sh
echo "Hello"
EOF
mkdir -p "${WT_A}/tests"
cat > "${WT_A}/tests/test_greet.sh" <<'EOF'
#!/bin/sh
out="$(sh ./greet.sh)"
test "$out" = "Hello" || { echo "FAIL: expected 'Hello', got '$out'" >&2; exit 1; }
echo "ok: greet prints Hello (d00001 spec)"
EOF
act "Session A @ .worktrees/${WT_A_NAME}" "writes greet.sh + tests/test_greet.sh, then commits"
git -C "${WT_A}" add -A >/dev/null 2>&1 \
  && git -C "${WT_A}" commit --quiet -m "greet: print Hello (d00001)" \
  || fail "commit in Session A's worktree failed"
demo_run "Session A @ .worktrees/${WT_A_NAME}" "${WT_A}" "sh test.sh" sh test.sh
expect_rc 0 "the suite should pass on the Hello implementation"
expect_out "ok: greet prints Hello (d00001 spec)" "the greet test should have run"
pass "Hello implementation committed and green inside A's worktree"

# ---------------------------------------------------------------------------
# [5/7] ユーザーの気が変わる — Session B が矛盾する新指示を記録（後勝ちの布石）
# ---------------------------------------------------------------------------
stage 5 "The user changes their mind — Session B records the new instruction" \
  "The user may talk to ANY session. B records the contradicting instruction verbatim; the" \
  "ledger's commit order numbers it d00002 — and the newest instruction always wins."
demo_run "Session B @ repo" "${SB}/repo" 'agents directive "greet must print Hi, <name>."' \
  "${AG}" directive "greet must print Hi, <name>."
expect_rc 0 "recording the new directive should succeed"
[ "$(first_line)" = "d00002" ] || fail "the new instruction should be numbered d00002 (got: $(first_line))"
pass "the contradicting instruction is in the ledger as d00002 — Session A has not seen it yet"

# ---------------------------------------------------------------------------
# [6/7] A の done がゲートに止まる → 後勝ちで作り直し → done --seen → 直列 merge
# ---------------------------------------------------------------------------
stage 6 "Session A tries to finish — the gate stops it, then A obeys the newest instruction" \
  "done refuses with exit 3 while unread directives exist, printing d00002 in full. A reworks," \
  "recites --seen d00002, and the serialized merge re-runs the whole suite before main moves."
demo_run "Session A @ .worktrees/${WT_A_NAME}" "${WT_A}" "agents done" "${AG}" done
expect_rc 3 "done should stop on the unseen directive"
expect_out "greet must print Hi, <name>." "the gate should print the unread directive in full"
expect_out "agents done --seen d00002 で復唱して再実行" "the gate should demand the recite (--seen d00002)"
pass "the unseen-directive gate stopped A's done (exit 3) and showed d00002 in full"

say "   d00002 contradicts A's finished work. Last-wins: A reworks to the Hi spec — no debate."
cat > "${WT_A}/greet.sh" <<'EOF'
#!/bin/sh
echo "Hi, ${1:-world}."
EOF
cat > "${WT_A}/tests/test_greet.sh" <<'EOF'
#!/bin/sh
out="$(sh ./greet.sh Alice)"
test "$out" = "Hi, Alice." || { echo "FAIL: expected 'Hi, Alice.', got '$out'" >&2; exit 1; }
echo "ok: greet prints Hi, <name>. (d00002 spec)"
EOF
act "Session A @ .worktrees/${WT_A_NAME}" "rewrites greet.sh + test to the Hi spec, then commits"
git -C "${WT_A}" commit --quiet -am "greet: print Hi, <name> (rework per d00002, last-wins)" \
  || fail "the rework commit failed"

demo_run "Session A @ .worktrees/${WT_A_NAME}" "${WT_A}" "agents done --seen d00002" \
  "${AG}" done --seen d00002
expect_rc 0 "done --seen d00002 should pass the gate, rebase, test, and push the branch"
expect_out "done: greet は ready" "done should mark the claim ready"
pass "recited --seen d00002 — rebase + full suite + branch push succeeded, claim is ready"

demo_run "Session A @ .worktrees/${WT_A_NAME}" "${WT_A}" "agents merge greet" "${AG}" merge greet
expect_rc 0 "agents merge should land the branch on main"
expect_out "test.sh: all tests passed" "merge should run the full suite on the merged tree"
expect_out "merged:" "merge should report the merge commit landing on main"
pass "serialized merge: lock -> clean worktree -> merge -> symbol check -> full suite -> FF push to main"

# ---------------------------------------------------------------------------
# [7/7] フィナーレ: main の履歴・greet の実出力・台帳
# ---------------------------------------------------------------------------
stage 7 "The proof — main's history, greet's output, and the audit ledger" \
  "main's tip is the one merge commit and its message recites seen d00002; greet answers with" \
  "the Hi spec (the newest instruction won); agent-state holds the complete audit trail."
git -C "${SB}/repo" fetch --quiet --prune origin || fail "final fetch from origin failed"
git -C "${SB}/repo" merge --ff-only --quiet refs/remotes/origin/main >/dev/null 2>&1 \
  || fail "fast-forwarding the checkout to the merged main failed"
demo_run "operator @ repo" "${SB}/repo" "git log --graph --oneline" git log --graph --oneline
expect_rc 0 "git log should work"
expect_out "merge greet (d00001, seen d00002)" "main should carry the merge commit that recites seen d00002"
SUBJ="$(git -C "${SB}/repo" log -1 --format=%s)"
[ "${SUBJ}" = "merge greet (d00001, seen d00002): implement greet" ] \
  || fail "unexpected subject at the tip of main: ${SUBJ}"
pass "main's tip is the serialized merge commit — directive and seen are recited in its message"

demo_run "operator @ repo" "${SB}/repo" "sh greet.sh Alice" sh greet.sh Alice
expect_rc 0 "greet should run from the merged main"
[ "$(first_line)" = "Hi, Alice." ] \
  || fail "greet should follow the newest instruction, got: $(first_line)"
pass 'greet prints "Hi, Alice." — physical evidence that the newest instruction (d00002) won'

demo_run "operator @ repo" "${SB}/repo" "git log --oneline origin/agent-state" \
  git log --oneline origin/agent-state
expect_rc 0 "the ledger should be readable with plain git"
expect_out "directive d00001" "the ledger should record the first instruction"
expect_out "claim greet" "the ledger should record the claim"
expect_out "directive d00002" "the ledger should record the contradicting instruction"
expect_out "seen greet 2" "the ledger should record A's recite of d00002"
expect_out "merge-log greet" "the ledger should record the merge log"
pass "the ledger is a complete audit trail: directives, claim, recite, ready, lock, merge log"

# ---------------------------------------------------------------------------
# まとめ
# ---------------------------------------------------------------------------
printf '\n%s\n' "${C_G}==== demo result: PASS=${CHECKS} FAIL=0 — the whole story ran green in ${SECONDS}s ====${C_0}"
say "Last-wins, proven end to end: d00002 (Hi) overrode d00001 (Hello), the claim race had"
say "exactly one winner, every merge was fully tested, and it is all auditable on origin/agent-state."
say "Next: run it on your own repo — ./install.sh /path/to/your-repo (see README)."
exit 0
