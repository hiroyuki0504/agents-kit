#!/bin/bash
# uninstall.sh — agents-kit v1 撤去スクリプト（install.sh の逆操作。冪等）
# https://github.com/hiroyuki0504/agents-kit (MIT License)
# 用法: uninstall.sh <target-repo-path> [--purge-remote] [--no-push] [--force]（path 省略時 .）
#   --purge-remote  remote の state ブランチ（監査台帳）も削除する（既定は残す）
#   --no-push       remote への書き込み（除去コミットの push / --purge-remote の削除）を保留する
#   --force         生きた claim / 未保存作業入り worktree があっても続行する
# 消すもの:
#   - pre-push フックの agents-kit ブロック（除去後に shebang 等しか残らないファイルはファイルごと削除）
#   - AGENTS.md / CLAUDE.md のポインタブロック（ブロック以外の既存内容は 1 字も変えない。
#     ブロックのみのファイルはファイルごと削除）
#   - .gitignore の kit 追記 2 行（/.worktrees/ と /.agents/config.json。他の行は変えない）
#   - worktree_root（既定 .worktrees/）配下の worktree（未コミット/未 push の作業が残るものは
#     列挙して拒否。--force で強行）
#   - .agents/ 一式（働くツリーと remote の main 双方。main へは除去コミットを push する）
# 残すもの: remote の state ブランチ（監査台帳。--purge-remote 指定時のみ削除）と、
#           ローカルの agent/* ブランチ（未 push 作業の安全網。不要なら git branch -D）。
# remote 不在/到達不能でもローカル撤去は進める（push 系だけ案内にフォールバック）。
# グローバル設定（~/.claude、git config --global、repo 外の hooksPath 先）には一切触れない。
set -u -o pipefail

command -v python3 >/dev/null 2>&1 || { echo "エラー: python3 が必要（README の動作環境を参照）" >&2; exit 1; }

T="."
PURGE_REMOTE=0
NO_PUSH=0
FORCE=0
for a in "$@"; do
  case "$a" in
    --purge-remote) PURGE_REMOTE=1 ;;
    --no-push) NO_PUSH=1 ;;
    --force) FORCE=1 ;;
    -*) echo "エラー: 未知のオプション: $a" >&2; exit 1 ;;
    *) T="$a" ;;
  esac
done
# 物理パスへ正規化（macOS の /var → /private/var 等。realpath 済みパスとの前綴比較を成立させる）
T="$(cd "$T" 2>/dev/null && pwd -P)" || { echo "エラー: ディレクトリが無い" >&2; exit 1; }

g() { LC_ALL=C LANG=C git -C "$T" "$@"; }

# push 失敗分類（kit/agents の PUSH_CAS_PATTERNS の詳細パターン部分集合。§5.3）。
# uninstall はリトライ判定に裸の \[rejected\] / \[remote rejected\] を使わない:
# 実測された CAS 本命レースは必ず詳細（non-fast-forward / fetch first / incorrect old value 等）を
# 伴う一方、branch protection やサーバ側フックの恒久拒否は
# "! [remote rejected] ... (pre-receive hook declined)" のように詳細を伴わないため。
# 裸マーカーまで CAS 扱いすると恒久拒否を 5 回無駄押しした挙句、回復手順が表示されない。
AGENTS_KIT_CAS_PATTERNS='non-fast-forward|fetch first|incorrect old value|failed to update ref|cannot lock ref'
is_cas_err() { printf '%s' "$1" | grep -Eq "$AGENTS_KIT_CAS_PATTERNS"; }

realpath_py() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# ---------------------------------------------------------------------------
# 手順1: 検証と検出（install.sh 手順1と同じ流儀。ただし remote 不在は致命傷にしない）
# ---------------------------------------------------------------------------
if ! g rev-parse --git-dir >/dev/null 2>&1; then
  echo "エラー: $T は git リポジトリではない" >&2
  exit 1
fi
COMMON_GITDIR="$(g rev-parse --path-format=absolute --git-common-dir)"

CFG="$T/.agents/config.json"
REMOTE="origin"
CFG_MAIN=""
CFG_STATE=""
WROOT=".worktrees"
TTL_H="24"
if [ -f "$CFG" ]; then
  REMOTE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("remote") or "origin")' "$CFG" 2>/dev/null || echo origin)"
  CFG_MAIN="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("main_branch") or "")' "$CFG" 2>/dev/null || echo "")"
  CFG_STATE="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("state_branch") or "")' "$CFG" 2>/dev/null || echo "")"
  WROOT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("worktree_root") or ".worktrees")' "$CFG" 2>/dev/null || echo .worktrees)"
  TTL_H="$(python3 -c 'import json,sys;v=json.load(open(sys.argv[1])).get("claim_ttl_hours");print(24 if v is None else v)' "$CFG" 2>/dev/null || echo 24)"
fi

REMOTE_OK=1
DETECTED=""
if g remote get-url "$REMOTE" >/dev/null 2>&1; then
  DETECTED="$(g ls-remote --symref "$REMOTE" HEAD 2>/dev/null | awk '$1=="ref:" && $2 ~ /^refs\/heads\// {sub("refs/heads/","",$2); print $2; exit}')"
  if [ -z "$DETECTED" ]; then
    REMOTE_OK=0
    echo "警告: remote '$REMOTE' に到達できない。ローカル撤去のみ行い、push 系（除去コミット/--purge-remote）は案内に切り替える"
  fi
else
  REMOTE_OK=0
  echo "警告: remote '$REMOTE' が無い。ローカル撤去のみ行う"
fi
MAIN="${CFG_MAIN:-${DETECTED:-main}}"
STATE="${CFG_STATE:-agent-state}"
case "$WROOT" in
  /*) WROOT_ABS="$WROOT" ;;
  *)  WROOT_ABS="$T/$WROOT" ;;
esac

# remote の全ブランチを取得（claim 生存確認と worktree の push 済み判定に使う。--prune で正確に）
STATE_TIP=""
MAIN_TIP=""
if [ "$REMOTE_OK" = 1 ]; then
  g fetch --quiet --prune "$REMOTE" "+refs/heads/*:refs/remotes/$REMOTE/*" 2>/dev/null || REMOTE_OK=0
  STATE_TIP="$(g rev-parse -q --verify "refs/remotes/$REMOTE/$STATE" 2>/dev/null || true)"
  MAIN_TIP="$(g rev-parse -q --verify "refs/remotes/$REMOTE/$MAIN" 2>/dev/null || true)"
fi

# フック設置先の解決（install.sh と同じ 2 配置ケース: 共有 gitdir / repo 内 core.hooksPath。
# repo 外 hooksPath は触らず案内のみ）
HP="$(g config --get core.hooksPath || true)"
HOOK_MODE="common"     # common | inrepo | outside
CHOOK_FILE="$COMMON_GITDIR/hooks/pre-push"
INREPO_HOOK_FILE=""
HOOK_REL_CAND=""       # T 相対（除去コミットの候補にする repo 内フックパス）
if [ -n "$HP" ]; then
  case "$HP" in
    /*) HP_ABS="$HP" ;;
    *)  HP_ABS="$T/$HP" ;;
  esac
  HP_ABS="$(realpath_py "$HP_ABS")"
  case "$HP_ABS/" in
    "$T"/*) HOOK_MODE="inrepo"; INREPO_HOOK_FILE="$HP_ABS/pre-push"; HOOK_REL_CAND="${INREPO_HOOK_FILE#"$T"/}" ;;
    *)      HOOK_MODE="outside" ;;
  esac
fi

# ポインタ/無視ファイルの実体解決（symlink は実体側を触り、リンクは保持。install.sh と同じ）
A_REAL="$(realpath_py "$T/AGENTS.md")"
C_REAL="$(realpath_py "$T/CLAUDE.md")"
GI_REAL="$(realpath_py "$T/.gitignore")"
rel_in_repo() { case "$1/" in "$T"/*) printf '%s' "${1#"$T"/}" ;; *) printf '' ;; esac; }
A_RELP="$(rel_in_repo "$A_REAL")"
C_RELP="$(rel_in_repo "$C_REAL")"
GI_RELP="$(rel_in_repo "$GI_REAL")"

# ---------------------------------------------------------------------------
# ブロック除去の共通変換（install.sh の kit_only_diff と同じマーカー判定）。
# stdin → stdout。exit 0=内容が残る / 3=実質空（ファイル削除・index からの削除に相当）。
#   ptr  : ポインタブロック行（>>> agents-kit >>> 〜 <<< agents-kit <<<）を除去。残りが空白のみなら 3
#   hook : フックブロック行を除去。残りが shebang・空行・`exit 0` のみ（= install.sh が
#          生成した完全ファイルの残骸）なら 3。コメント等の既存内容が 1 行でもあれば残す
#   gi   : /.worktrees/ と /.agents/config.json の 2 行（完全一致）だけを除去。残りが空なら 3
# ローカルファイルと除去コミットの両方でこの同一変換を使う（結果の blob 一致 = reconcile 可能）。
# ---------------------------------------------------------------------------
kit_strip() {  # $1=ptr|hook|gi
  python3 -c '
import sys
mode = sys.argv[1]
data = sys.stdin.buffer.read().decode("utf-8", "surrogateescape")
lines = data.split("\n")
if mode in ("ptr", "hook"):
    s = ">>> agents-kit >>>" if mode == "ptr" else ">>> agents-kit pre-push >>>"
    e = "<<< agents-kit <<<" if mode == "ptr" else "<<< agents-kit pre-push <<<"
    out, inblk = [], False
    for ln in lines:
        if s in ln:
            inblk = True
            continue
        if e in ln:
            inblk = False
            continue
        if not inblk:
            out.append(ln)
else:
    out = [ln for ln in lines if ln not in ("/.worktrees/", "/.agents/config.json")]
text = "\n".join(out)
if mode == "hook":
    empty = all((not t) or t.startswith("#!") or t == "exit 0"
                for t in (ln.strip() for ln in out))
else:
    empty = text.strip() == ""
sys.stdout.buffer.write(text.encode("utf-8", "surrogateescape"))
sys.exit(3 if empty else 0)
' "$1"
}

strip_local() {  # $1=実体ファイルの絶対パス $2=mode → stdout: none|stripped|deleted|error（表示は呼び出し側）
  local f="$1" mode="$2" tmp rc
  [ -f "$f" ] || { echo none; return 0; }
  case "$mode" in
    ptr)  grep -qF '>>> agents-kit >>>' "$f" 2>/dev/null || { echo none; return 0; } ;;
    hook) grep -qF '>>> agents-kit pre-push >>>' "$f" 2>/dev/null || { echo none; return 0; } ;;
    gi)   { grep -qxF '/.worktrees/' "$f" 2>/dev/null || grep -qxF '/.agents/config.json' "$f" 2>/dev/null; } \
            || { echo none; return 0; } ;;
  esac
  tmp="$COMMON_GITDIR/agents-tmp-un.$$"
  kit_strip "$mode" < "$f" > "$tmp"
  rc=$?
  if [ $rc -eq 3 ]; then
    rm -f "$f" "$tmp"
    echo deleted
  elif [ $rc -eq 0 ]; then
    cat "$tmp" > "$f"   # > で書き実体化を防ぐ（symlink 保持。パーミッションも保持）
    rm -f "$tmp"
    echo stripped
  else
    rm -f "$tmp"
    echo error
  fi
}

# reconcile 失敗時の巻き戻し用: ローカル除去だけを再適用する（全操作が冪等）
apply_local_removals() {
  if [ "$HOOK_MODE" != "outside" ]; then
    strip_local "$CHOOK_FILE" hook >/dev/null
    [ -n "$INREPO_HOOK_FILE" ] && strip_local "$INREPO_HOOK_FILE" hook >/dev/null
  fi
  strip_local "$A_REAL" ptr >/dev/null
  [ "$C_REAL" != "$A_REAL" ] && strip_local "$C_REAL" ptr >/dev/null
  strip_local "$GI_REAL" gi >/dev/null
  rm -rf "$T/.agents"
  return 0
}

# ---------------------------------------------------------------------------
# 撤去対象の有無を先に調べる（2 回目実行の冪等 exit 0 のため）
# ---------------------------------------------------------------------------
has_marker() { [ -f "$1" ] && grep -qF "$2" "$1" 2>/dev/null; }
HAS_LOCAL=0
[ -e "$T/.agents" ] && HAS_LOCAL=1
has_marker "$CHOOK_FILE" '>>> agents-kit pre-push >>>' && HAS_LOCAL=1
[ -n "$INREPO_HOOK_FILE" ] && has_marker "$INREPO_HOOK_FILE" '>>> agents-kit pre-push >>>' && HAS_LOCAL=1
has_marker "$A_REAL" '>>> agents-kit >>>' && HAS_LOCAL=1
has_marker "$C_REAL" '>>> agents-kit >>>' && HAS_LOCAL=1
if [ -f "$GI_REAL" ] && { grep -qxF '/.worktrees/' "$GI_REAL" 2>/dev/null \
     || grep -qxF '/.agents/config.json' "$GI_REAL" 2>/dev/null; }; then HAS_LOCAL=1; fi
[ -d "$WROOT_ABS" ] && [ -n "$(ls -A "$WROOT_ABS" 2>/dev/null)" ] && HAS_LOCAL=1

HAS_REMOTE=0
if [ -n "$MAIN_TIP" ] && [ -n "$(g ls-tree -d --name-only "$MAIN_TIP" -- .agents 2>/dev/null)" ]; then
  HAS_REMOTE=1
fi

FAILRC=0
DONE_LINES=""
KEPT_LINES=""
add_done() { DONE_LINES="${DONE_LINES}  - $1
"; }
add_kept() { KEPT_LINES="${KEPT_LINES}  - $1
"; }

# state ブランチの扱い（既定は残す / --purge-remote で削除 / --no-push で保留）
purge_state() {
  if [ "$NO_PUSH" = 1 ]; then
    echo "state ブランチの削除は保留した（--no-push）。--purge-remote を付けて再実行せよ"
    add_kept "remote の ${STATE}（--no-push のため削除保留）"
    return 0
  fi
  if [ "$REMOTE_OK" != 1 ]; then
    echo "エラー: remote に到達できず ${STATE} を削除できない。到達可能な環境で --purge-remote を付けて再実行せよ" >&2
    FAILRC=1
    return 0
  fi
  if [ -z "$(g ls-remote "$REMOTE" "refs/heads/$STATE" 2>/dev/null)" ]; then
    echo "remote の ${STATE} は既に無い（削除不要）"
    return 0
  fi
  local ERR
  ERR="$(AGENTS_STATE_TOKEN=1 g push "$REMOTE" ":refs/heads/$STATE" 2>&1 >/dev/null)" || {
    echo "エラー: state ブランチ（${STATE}）の削除が拒否された:" >&2
    printf '%s\n' "$ERR" >&2
    echo "branch protection（Allow deletions オフ）が原因なら一時的に許可するか、ホスティング側の UI で refs/heads/${STATE} を削除せよ" >&2
    FAILRC=1
    return 0
  }
  g update-ref -d "refs/remotes/$REMOTE/$STATE" 2>/dev/null
  echo "remote の ${STATE} を削除した（--purge-remote）"
  add_done "remote の state ブランチ ${STATE}（監査台帳ごと削除）"
}

keep_state_note() {
  if [ "$REMOTE_OK" = 1 ] && [ -n "$STATE_TIP" ]; then
    echo "remote の ${STATE} は監査台帳としてそのまま残した（消す場合: uninstall.sh --purge-remote、または git push ${REMOTE} :refs/heads/${STATE}）"
    add_kept "remote の state ブランチ ${STATE}（監査台帳。--purge-remote で削除可）"
  fi
}

# 撤去済み（または未導入）なら何も変更せず終了（冪等）
if [ "$HAS_LOCAL" = 0 ] && { [ "$REMOTE_OK" != 1 ] || [ "$HAS_REMOTE" = 0 ]; }; then
  echo ""
  echo "==== agents-kit は撤去済み（または未導入）: $T ===="
  echo "撤去対象が無いため何も変更していない。"
  if [ "$PURGE_REMOTE" = 1 ]; then
    purge_state
  else
    keep_state_note
  fi
  exit $FAILRC
fi

# ---------------------------------------------------------------------------
# 手順2: 生きた claim の確認（state を fetch 済み。生存 = claim_ttl_hours 以内に refresh）
# ---------------------------------------------------------------------------
if [ "$REMOTE_OK" = 1 ] && [ -n "$STATE_TIP" ]; then
  LIVE="$(python3 - "$T" "$STATE_TIP" "$TTL_H" <<'PYEOF'
import json, os, subprocess, sys
from datetime import datetime, timezone
T, tip, ttl_h = sys.argv[1], sys.argv[2], float(sys.argv[3])
def g(*a):
    return subprocess.run(["git", "-C", T] + list(a), capture_output=True,
                          env=dict(os.environ, LC_ALL="C", LANG="C"))
r = g("ls-tree", "-r", "--name-only", tip)
if r.returncode != 0:
    sys.exit(0)
def age_min(iso):
    try:
        t = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
    except Exception:
        return None
    return (datetime.now(timezone.utc) - t).total_seconds() / 60.0
def fmt(m):
    if m is None:
        return "?"
    if m < 1:
        return "たった今"
    if m < 60:
        return "%d分前" % int(m)
    if m < 1440:
        return "%.1f時間前" % (m / 60)
    return "%.1f日前" % (m / 1440)
for n in r.stdout.decode("utf-8", "surrogateescape").split("\n"):
    if not (n.startswith("claims/") and n.endswith(".json")):
        continue
    raw = g("cat-file", "blob", "%s:%s" % (tip, n)).stdout
    try:
        c = json.loads(raw.decode("utf-8", "surrogateescape"))
    except Exception:
        c = {}
    m = age_min(c.get("refreshed_at"))
    if m is not None and m > ttl_h * 60:
        continue   # stale（TTL 切れ）は撤去を止めない
    print("  %s  agent=%s  最終更新=%s  intent=%s" % (
        c.get("slug") or n[len("claims/"):-len(".json")],
        c.get("agent", "?"), fmt(m), c.get("intent", "")))
PYEOF
)"
  if [ -n "$LIVE" ]; then
    echo "生きた claim が state（${STATE}）にある。他セッションが作業中の可能性:"
    printf '%s\n' "$LIVE"
    if [ "$FORCE" = 1 ]; then
      echo "警告: --force 指定のため続行する（該当セッションの作業は放棄される前提）"
    else
      cat >&2 <<EOF
エラー: 撤去を中断した。各セッションの完了（agents merge / agents release）を待って再実行せよ。
TTL 切れの残骸なら .agents/bin/agents evict --dry-run で生死確認の上 evict で掃除できる。
確実に無人だと分かっている場合のみ --force で続行できる。
EOF
      exit 1
    fi
  fi
elif [ "$REMOTE_OK" != 1 ]; then
  echo "警告: remote に到達できないため claim の生存確認はできない（ローカル撤去は続行）"
fi

# ---------------------------------------------------------------------------
# 手順3: pre-push フックのブロック除去（共有 gitdir と repo 内 hooksPath の両方を掃除。
#         repo 外 hooksPath は触らず案内のみ）
# ---------------------------------------------------------------------------
disp() {  # 表示用: repo 配下なら T 相対で短く（判定や操作には使わない）
  case "$1/" in
    "$T"/*) printf '%s' "${1#"$T"/}" ;;
    *)      printf '%s' "$1" ;;
  esac
}
report_strip() {  # $1=結果 $2=表示名 $3=削除時の補足
  case "$1" in
    stripped) echo "${2} の agents-kit ブロックを除去した"; add_done "${2} のブロック" ;;
    deleted)  echo "${2} を削除した（${3}）"; add_done "${2}（ファイルごと削除: ${3}）" ;;
    error)    echo "警告: ${2} のブロック除去に失敗した（読めない/書けない）。手で確認せよ" >&2; FAILRC=1 ;;
  esac
}
RES="$(strip_local "$CHOOK_FILE" hook)"
report_strip "$RES" "$(disp "$CHOOK_FILE")" "kit 生成のフックのみだったため"
if [ -n "$INREPO_HOOK_FILE" ]; then
  RES="$(strip_local "$INREPO_HOOK_FILE" hook)"
  report_strip "$RES" "$(disp "$INREPO_HOOK_FILE")" "kit 生成のフックのみだったため"
fi
if [ "$HOOK_MODE" = "outside" ]; then
  printf '注意: core.hooksPath が repo 外（%s）を指しているため、そこは触らない。\n%s/pre-push に agents-kit ブロックが残っていれば、マーカー行「# >>> agents-kit pre-push >>>」〜「# <<< agents-kit pre-push <<<」を手で除去せよ。\n' "$HP" "$HP"
  add_kept "repo 外 hooksPath（${HP}）のフック（手動除去が必要なら上記の案内どおり）"
fi

# ---------------------------------------------------------------------------
# 手順4: AGENTS.md / CLAUDE.md のポインタブロック除去（symlink は実体側。
#         ブロック以外の既存内容は 1 字も変えない。ブロックのみのファイルは削除）
# ---------------------------------------------------------------------------
RES="$(strip_local "$A_REAL" ptr)"
report_strip "$RES" "$(disp "$A_REAL")" "ポインタブロックのみのファイルだったため"
if [ "$C_REAL" != "$A_REAL" ]; then
  RES="$(strip_local "$C_REAL" ptr)"
  report_strip "$RES" "$(disp "$C_REAL")" "ポインタブロックのみのファイルだったため"
fi

# ---------------------------------------------------------------------------
# 手順5: .gitignore の kit 追記 2 行を除去（行の完全一致のみ。他の行は変えない）
# ---------------------------------------------------------------------------
RES="$(strip_local "$GI_REAL" gi)"
report_strip "$RES" "$(disp "$GI_REAL")" "kit 追記行のみのファイルだったため"

# ---------------------------------------------------------------------------
# 手順6: worktree_root 配下の worktree を除去
#   未コミット/未 push の作業が残るものは列挙して拒否（--force で強行）。
#   push 済み判定は remote-tracking（refs/remotes/*）基準。remote 不到達時は手元の情報での最善判定。
# ---------------------------------------------------------------------------
WT_BLOCKED=""
WT_TARGETS=""
WT_JUNK=""
if [ -d "$WROOT_ABS" ]; then
  for d in "$WROOT_ABS"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    if [ ! -f "$d/.git" ]; then
      WT_JUNK="${WT_JUNK}${d}
"
      continue
    fi
    dirty="$(git -C "$d" status --porcelain 2>/dev/null)"
    hsha="$(git -C "$d" rev-parse -q --verify HEAD 2>/dev/null || true)"
    pushed=0
    if [ -n "$hsha" ] && [ -n "$(g branch -r --contains "$hsha" 2>/dev/null)" ]; then
      pushed=1
    fi
    reason=""
    [ -n "$dirty" ] && reason="未コミットの変更"
    if [ "$pushed" = 0 ]; then
      reason="${reason:+${reason} / }未 push のコミット"
    fi
    if [ -n "$reason" ]; then
      WT_BLOCKED="${WT_BLOCKED}  $(disp "$d")（${reason}）
"
    fi
    WT_TARGETS="${WT_TARGETS}${d}
"
  done
fi
if [ -n "$WT_BLOCKED" ] && [ "$FORCE" != 1 ]; then
  echo "エラー: 未保存の作業が残る worktree があるため撤去を中断した:" >&2
  printf '%s' "$WT_BLOCKED" >&2
  cat >&2 <<EOF
作業を退避（commit して push、または手動コピー）してから再実行せよ。破棄してよければ --force を付けよ。
ここまでの除去（フック/ポインタブロック等）は完了済み。再実行すれば続きから冪等に進む。
EOF
  exit 1
fi
WT_REMOVED=0
if [ -n "$WT_TARGETS" ]; then
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$FORCE" = 1 ]; then
      WERR="$(g worktree remove --force -- "$d" 2>&1)" || {
        echo "警告: worktree を除去できなかった: $d" >&2
        printf '%s\n' "$WERR" >&2
        echo "手動で: git -C ${T} worktree remove --force -- ${d}" >&2
        FAILRC=1
        continue
      }
    else
      WERR="$(g worktree remove -- "$d" 2>&1)" || {
        echo "警告: worktree を除去できなかった: $d" >&2
        printf '%s\n' "$WERR" >&2
        echo "手動で: git -C ${T} worktree remove --force -- ${d}" >&2
        FAILRC=1
        continue
      }
    fi
    echo "worktree を除去した: $(disp "$d")"
    WT_REMOVED=$((WT_REMOVED+1))
  done < <(printf '%s\n' "$WT_TARGETS")
fi
g worktree prune 2>/dev/null
[ "$WT_REMOVED" -gt 0 ] && add_done "worktree ${WT_REMOVED} 件（${WROOT}/ 配下）"
if [ -n "$WT_JUNK" ]; then
  echo "注意: ${WROOT}/ に worktree でない残置物がある（触らない）:"
  printf '%s' "$WT_JUNK" | sed 's/^/  /'
  add_kept "${WROOT}/ 配下の worktree でない残置物（内容を確認して手で消せ）"
fi
rmdir "$WROOT_ABS" 2>/dev/null && add_done "空になった ${WROOT}/"

# ---------------------------------------------------------------------------
# 手順7: .agents/ を働くツリーから除去し、remote main へ除去コミットを push
#   コミットは remote main の TIP から plumbing で構築する（working tree の未コミット変更を
#   巻き込まない）。変換はローカルと同一の kit_strip。フックは手順3で除去済みだが、
#   repo 外 hooksPath が残るケースでも進むよう install.sh と同じ管理ツール経路（トークン）で push する。
# ---------------------------------------------------------------------------
if [ -e "$T/.agents" ]; then
  rm -rf "$T/.agents"
  echo ".agents/ を働くツリーから削除した"
  add_done ".agents/ 一式（働くツリー）"
fi

UNINSTALL_COMMIT=""
build_and_push_removal() {  # $1=リトライ回数。0=push済 / 42=CAS敗北 / 43=remote main 無し / 44=remote に痕跡なし / 1=失敗
  local attempt="$1" TIP TMPIDX TMP1 TMP2 TREE PUSH_ERR p m blob mode_bits nb rc CANDS
  g fetch --quiet "$REMOTE" "+refs/heads/$MAIN:refs/remotes/$REMOTE/$MAIN" 2>/dev/null
  TIP="$(g rev-parse -q --verify "refs/remotes/$REMOTE/$MAIN" 2>/dev/null || true)"
  [ -n "$TIP" ] || return 43
  mkdir -p "$COMMON_GITDIR/agents-tmp"
  TMPIDX="$COMMON_GITDIR/agents-tmp/idx-uninstall-$$-$attempt"
  TMP1="$COMMON_GITDIR/agents-tmp/blob-old-$$"
  TMP2="$COMMON_GITDIR/agents-tmp/blob-new-$$"
  GIT_INDEX_FILE="$TMPIDX" g read-tree "$TIP^{tree}" || return 1
  # (i) .agents/ 配下の追跡ファイルを index から除去
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    GIT_INDEX_FILE="$TMPIDX" g update-index --force-remove -- "$p" || return 1
  done < <(g ls-tree -r --name-only "$TIP" -- .agents 2>/dev/null)
  # (ii) ポインタ/無視/フックの各候補パスを TIP の blob からブロック除去して差し替え
  CANDS="$(
    printf '%s\t%s\n' "AGENTS.md" ptr "CLAUDE.md" ptr ".gitignore" gi
    [ -n "$A_RELP" ] && printf '%s\t%s\n' "$A_RELP" ptr
    [ -n "$C_RELP" ] && printf '%s\t%s\n' "$C_RELP" ptr
    [ -n "$GI_RELP" ] && printf '%s\t%s\n' "$GI_RELP" gi
    [ -n "$HOOK_REL_CAND" ] && printf '%s\t%s\n' "$HOOK_REL_CAND" hook
    true
  )"
  local SEEN=" "
  while IFS=$'\t' read -r p m; do
    [ -n "$p" ] || continue
    case "$SEEN" in *" $p "*) continue ;; esac
    SEEN="$SEEN$p "
    blob="$(g rev-parse -q --verify "$TIP:$p" 2>/dev/null || true)"
    [ -n "$blob" ] || continue
    mode_bits="$(g ls-tree "$TIP" -- "$p" 2>/dev/null | awk '{print $1; exit}')"
    [ "$mode_bits" = "120000" ] && continue   # 追跡 symlink はリンク先候補が別途カバーする
    g cat-file blob "$blob" > "$TMP1" || return 1
    kit_strip "$m" < "$TMP1" > "$TMP2"
    rc=$?
    if [ $rc -eq 3 ]; then
      GIT_INDEX_FILE="$TMPIDX" g update-index --force-remove -- "$p" || return 1
    elif [ $rc -eq 0 ]; then
      if ! cmp -s "$TMP1" "$TMP2"; then
        nb="$(g hash-object -w "$TMP2")" || return 1
        GIT_INDEX_FILE="$TMPIDX" g update-index --cacheinfo "$mode_bits,$nb,$p" || return 1
      fi
    else
      return 1
    fi
  done < <(printf '%s\n' "$CANDS")
  TREE="$(GIT_INDEX_FILE="$TMPIDX" g write-tree)" || return 1
  rm -f "$TMPIDX" "$TMP1" "$TMP2"
  if [ "$TREE" = "$(g rev-parse "$TIP^{tree}")" ]; then
    return 44
  fi
  UNINSTALL_COMMIT="$(g -c user.name=agents-kit -c user.email=agents-kit@local commit-tree "$TREE" -p "$TIP" -m 'agents-kit: uninstall')" || return 1
  PUSH_ERR="$(AGENTS_MERGE_TOKEN=1 g push "$REMOTE" "$UNINSTALL_COMMIT:refs/heads/$MAIN" 2>&1 >/dev/null)" && {
    echo "除去コミットを push した（remote の ${MAIN} から .agents 一式と各ブロックを消した）: $UNINSTALL_COMMIT"
    return 0
  }
  if is_cas_err "$PUSH_ERR"; then
    return 42
  fi
  echo "エラー: 除去コミットの push が拒否された:" >&2
  printf '%s\n' "$PUSH_ERR" >&2
  cat >&2 <<EOF
回復手順: 拒否原因（branch protection の Require PR / サーバ側フック等）を解消してから uninstall.sh を再実行せよ
（除去コミットは作り直される）。または通常の PR/マージ手順で ${MAIN} から .agents 一式・
AGENTS.md / CLAUDE.md のポインタブロック・.gitignore の kit 行を除去せよ。
除去コミット ${UNINSTALL_COMMIT} はローカルに残っている
（解消後に git push ${REMOTE} ${UNINSTALL_COMMIT}:refs/heads/${MAIN} でも再送できる）。
EOF
  return 1
}

reconcile_checkout() {  # $1=除去コミット SHA。ローカル checkout（main）を FF で追いつかせる
  local NEW="$1" cur p blob st
  cur="$(g symbolic-ref --quiet --short HEAD || true)"
  if [ "$cur" != "$MAIN" ]; then
    echo "注意: 現在のブランチが ${MAIN} でないため checkout は自動で進めない。${MAIN} に戻ったら git pull せよ"
    return 0
  fi
  [ "$(g rev-parse HEAD 2>/dev/null)" = "$NEW" ] && return 0
  if ! g merge-base --is-ancestor HEAD "$NEW" 2>/dev/null; then
    echo "注意: ローカル ${MAIN} が remote と分岐している。自動では進めない（git pull --rebase 等で手動解消）"
    return 0
  fi
  # 除去コミットが触ったパスのうち、working の状態が既に NEW と一致しているものだけを
  # 一旦 HEAD 版へ戻し（= 追跡上クリーンにし）、FF で NEW の状態に着地させる。
  while IFS= read -r -d '' p; do
    [ -n "$p" ] || continue
    st="$(g status --porcelain -uno -- "$p" 2>/dev/null)"
    [ -n "$st" ] || continue
    blob="$(g rev-parse -q --verify "$NEW:$p" 2>/dev/null || true)"
    if [ -n "$blob" ]; then
      if [ -f "$T/$p" ] && [ "$(g hash-object "$T/$p")" = "$blob" ]; then :; else
        apply_local_removals
        echo "注意: ${p} に未コミットの変更があるため checkout は自動で進めない。commit 後に git pull せよ（kit ファイルのローカル除去は完了済み）"
        return 0
      fi
    else
      if [ -e "$T/$p" ]; then
        apply_local_removals
        echo "注意: ${p} が残っているため checkout は自動で進めない。git pull を手で行え（kit ファイルのローカル除去は完了済み）"
        return 0
      fi
    fi
    g checkout --quiet -- "$p" 2>/dev/null || {
      apply_local_removals
      echo "注意: ${p} を戻せず checkout の自動前進を中止した。git pull を手で行え"
      return 0
    }
  done < <(g diff --name-only -z HEAD "$NEW")
  if g merge --ff-only "$NEW" >/dev/null 2>&1; then
    echo "ローカル checkout を ${MAIN} 最新（除去コミット）へ前進させた（この後の git pull は不要）"
  else
    apply_local_removals
    echo "注意: checkout の自動前進に失敗した。git pull を手で行え（kit ファイルのローカル除去は完了済み）"
  fi
  return 0
}

if [ "$REMOTE_OK" != 1 ]; then
  echo "注意: remote に到達できないため除去コミットの push は行っていない。到達可能な環境で uninstall.sh を再実行せよ（ローカル撤去は完了済み）"
  add_kept "remote の ${MAIN} 上の .agents 一式（未 push。再実行で除去される）"
elif [ "$NO_PUSH" = 1 ]; then
  echo "除去コミットの push は保留した（--no-push）。内容を確認したら uninstall.sh を再実行せよ（uninstall.sh が push する）"
  add_kept "remote の ${MAIN} 上の .agents 一式（--no-push のため保留）"
else
  ok=1
  for i in 1 2 3 4 5; do
    build_and_push_removal "$i"
    rc=$?
    if [ $rc -eq 0 ]; then
      ok=0
      add_done "remote の ${MAIN} から .agents 一式・ポインタブロック・.gitignore の kit 行（除去コミット push 済み）"
      reconcile_checkout "$UNINSTALL_COMMIT"
      break
    fi
    if [ $rc -eq 42 ]; then continue; fi
    if [ $rc -eq 43 ]; then
      echo "remote に ${MAIN} が無いため除去コミットは不要（push もしない）"
      ok=0
      break
    fi
    if [ $rc -eq 44 ]; then
      echo "remote の ${MAIN} に kit の痕跡は無い（除去コミットは不要）"
      ok=0
      break
    fi
    FAILRC=1
    ok=0
    break
  done
  if [ $ok -ne 0 ]; then
    echo "エラー: 除去コミットの push が CAS 敗北を 5 回超えた。少し待って uninstall.sh を再実行せよ" >&2
    FAILRC=1
  fi
fi

# ---------------------------------------------------------------------------
# 手順8: state ブランチ（既定で残す = 監査台帳。--purge-remote 指定時のみ削除）
# ---------------------------------------------------------------------------
if [ "$PURGE_REMOTE" = 1 ]; then
  purge_state
else
  keep_state_note
fi

# ---------------------------------------------------------------------------
# 手順9: まとめ（何を消し、何を残したか + 他クローンでの後始末）
# ---------------------------------------------------------------------------
AGBR="$(g for-each-ref --format='%(refname:short)' refs/heads/agent 2>/dev/null)"
if [ -n "$AGBR" ]; then
  add_kept "ローカルブランチ: $(printf '%s' "$AGBR" | tr '\n' ' ')（--force で消した作業もここに残る。不要なら git branch -D）"
fi

echo ""
if [ "$FAILRC" -eq 0 ]; then
  echo "==== agents-kit 撤去完了: $T ===="
else
  echo "==== agents-kit 撤去: 一部失敗（上記エラーを解消して再実行せよ）: $T ===="
fi
if [ -n "$DONE_LINES" ]; then
  echo "消したもの:"
  printf '%s' "$DONE_LINES"
fi
if [ -n "$KEPT_LINES" ]; then
  echo "残したもの:"
  printf '%s' "$KEPT_LINES"
fi
echo "他クローンの後始末: 各クローンで uninstall.sh <path> を一度実行せよ（git pull だけではフック・.agents/config.json・worktree が残る）"
exit $FAILRC
