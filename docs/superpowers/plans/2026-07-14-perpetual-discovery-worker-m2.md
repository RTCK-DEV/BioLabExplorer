# Perpetual Discovery Worker — M2（常駐化・launchd）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** M1 のオフラインサイクルを launchd で**連続実行（終わり次第次）**する常駐ワーカーにする。落ちても復帰し、連続失敗で自動停止（サーキットブレーカ）、真の停止は unload。

**Architecture:** 既存 `run_discovery_cycle.sh`（1サイクル=有限実行）を無改造の原則で拡張し、launchd `KeepAlive` が終了ごとに再起動＝back-to-back。`ThrottleInterval` で最小間隔。新規は plist 生成＋管理スクリプトと、サイクルの hardening（pidless ロック修復・ロック解放 trap 前倒し・PAUSED サーキットブレーカ）。ネットワーク・シミュ・可視化は無関係。

**Tech Stack:** bash 3.2/BSD, python3 stdlib, launchd(`launchctl`), `plutil`。テストは shell アサーション（実際の `launchctl load` はテストで実行しない＝plist 生成正当性と resume を検証）。

## Global Constraints（各タスクに暗黙適用）
- 既存 Swift 非改変。M1 の 8 cycle テスト＋config/db/status テストを壊さない。
- ネットワーク非使用（M2）。python3 stdlib＋bash 3.2/BSD。
- 生成物・状態はローカルのみ（gitignore）。plist は `launchd/`（追跡）にテンプレとして置き、実インストールは `~/Library/LaunchAgents/` へコピー。
- **自動テストで実 launchd エージェントを load しない**（環境汚染回避）。plist 生成の正当性(`plutil -lint`)と状態遷移を検証する。
- ブランチ: `feature/perpetual-discovery-worker-m2`。

## File Structure
- Modify `scripts/run_discovery_cycle.sh` — pidless ロック修復・ロック解放 trap 前倒し・PAUSED ゲート・連続失敗カウンタ＋サーキットブレーカ。
- Modify `config/worker.json` — `maxConsecutiveFailures`, `throttleSeconds` 追加。
- Modify `Tests/perpetual/test_config.sh` — 新キー検証。
- Create `scripts/discovery_agent.sh` — `generate|install|uninstall|status|resume`。
- Create `Tests/perpetual/test_agent.sh` — plist 生成正当性＋resume。
- Create `Tests/perpetual/test_cycle_daemon.sh` — pidless 修復・PAUSED ゲート・サーキットブレーカ。
- Modify `Tests/perpetual/run_all.sh` — 新テスト追加。
- Modify `README.md` — M2 常駐セクション。
- `launchd/`（新規ディレクトリ・`.gitkeep`）。

---

### Task 1: サイクル hardening（ロック・サーキットブレーカ）＋config

**Files:** Modify `scripts/run_discovery_cycle.sh`, `config/worker.json`, `Tests/perpetual/test_config.sh`; Create `Tests/perpetual/test_cycle_daemon.sh`.

**Interfaces:** Produces: `state/PAUSED`（存在で全サイクル no-op）、`state/consecutive_failures`（連続失敗数）。`resume` は両者を削除して復帰。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/perpetual/test_cycle_daemon.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CYCLE="${ROOT}/scripts/run_discovery_cycle.sh"

sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/state/inbox/processed" "$d/runs" "$d/discoveries" "$d/ref" "$d/logs"
  printf '>ref\nMKTAYIAKQR\n' > "$d/ref/ref.fasta"
  printf '{"diskFloorGB":0,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":200,"budgetSeconds":60,"maxConsecutiveFailures":2,"throttleSeconds":300}' > "$d/worker.json"
  echo "$d"
}
ok_pipe="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh"
fail_pipe="bash -c 'exit 7'"
run() {  # $1=sandbox $2=pipeline_cmd
  STATE_DIR="$1/state" RUNS_DIR="$1/runs" DISCOVERIES_DIR="$1/discoveries" \
  REFERENCE="$1/ref/ref.fasta" LOG_DIR="$1/logs" NOTIFY_CMD="true" \
  CONFIG="$1/worker.json" PIPELINE_CMD="$2" bash "$CYCLE"
}
count_actionable() { python3 "${ROOT}/scripts/discovery_db.py" count-actionable --db "$1/discoveries/ledger.db"; }

# 1) PAUSED gate: present -> no-op, no run dir
S="$(sandbox)"; : > "$S/state/PAUSED"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"
run "$S" "$ok_pipe"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: PAUSED ran a cycle"; exit 1; }
[[ -f "$S/state/inbox/b.fasta" ]] || { echo "FAIL: PAUSED consumed batch"; exit 1; }

# 2) pidless stale lock is reclaimed (lock dir exists, no pid file)
S="$(sandbox)"; mkdir -p "$S/state/.lock"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"
run "$S" "$ok_pipe"
[[ "$(count_actionable "$S")" == "1" ]] || { echo "FAIL: pidless lock not reclaimed"; exit 1; }

# 3) circuit breaker: maxConsecutiveFailures=2 -> after 2 failed cycles, PAUSED written
S="$(sandbox)"
printf '>x\nMKT\n' > "$S/state/inbox/f1.fasta"; set +e; run "$S" "$fail_pipe"; set -e
[[ ! -f "$S/state/PAUSED" ]] || { echo "FAIL: paused too early (after 1)"; exit 1; }
[[ "$(cat "$S/state/consecutive_failures")" == "1" ]] || { echo "FAIL: failcount!=1"; exit 1; }
printf '>x\nMKT\n' > "$S/state/inbox/f2.fasta"; set +e; run "$S" "$fail_pipe"; set -e
[[ -f "$S/state/PAUSED" ]] || { echo "FAIL: circuit breaker did not trip at 2"; exit 1; }

# 4) success resets the failure streak
S="$(sandbox)"
printf '>x\nMKT\n' > "$S/state/inbox/f1.fasta"; set +e; run "$S" "$fail_pipe"; set -e
[[ "$(cat "$S/state/consecutive_failures")" == "1" ]] || { echo "FAIL: pre-reset failcount"; exit 1; }
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/ok.fasta"; run "$S" "$ok_pipe"
[[ ! -f "$S/state/consecutive_failures" ]] || { echo "FAIL: success did not reset streak"; exit 1; }

echo "cycle daemon tests OK"
```

- [ ] **Step 2: 失敗確認** — Run: `bash Tests/perpetual/test_cycle_daemon.sh` → FAIL（PAUSED ゲート/カウンタ未実装）。

- [ ] **Step 3: 実装**

`config/worker.json` に2キー追加（既存値は保持）:
```json
{
  "diskFloorGB": 10,
  "maxCandidates": 20,
  "maxWorkspaceBytes": 21474836480,
  "maxLogFiles": 200,
  "budgetSeconds": 21600,
  "maxConsecutiveFailures": 5,
  "throttleSeconds": 300
}
```

`Tests/perpetual/test_config.sh` の必須intキー集合に `maxConsecutiveFailures`, `throttleSeconds` を追加（既存の python ブロックの `for k in (...)` に2キーを足す）。

`scripts/run_discovery_cycle.sh` を次のとおり編集:

(a) STOP ゲートの直後に PAUSED ゲートを追加:
```bash
if [[ -f "${STATE_DIR}/STOP" ]]; then log "STOP present -> graceful stop"; exit 0; fi
if [[ -f "${STATE_DIR}/PAUSED" ]]; then log "PAUSED (circuit breaker) -> no-op; resume via scripts/discovery_agent.sh resume"; exit 0; fi
```

(b) ロック取得ブロックを、pidless を stale 扱いにし、取得直後にロック解放 trap を張る形へ置換:
```bash
# ---------- single-instance lock (atomic mkdir; reclaim stale incl. pidless) ----------
mkdir -p "${STATE_DIR}" "${LOG_DIR}"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  oldpid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo "")"
  # Reclaim if no pid was ever written (died between mkdir and pid write) OR the pid is dead.
  if [[ -z "${oldpid}" ]] || ! kill -0 "${oldpid}" 2>/dev/null; then
    log "reclaiming stale lock (pid='${oldpid:-none}')"; rm -rf "${LOCK_DIR}"
    mkdir "${LOCK_DIR}" 2>/dev/null || { log "lock race -> exit"; exit 0; }
  else
    log "another live cycle holds the lock (pid ${oldpid}) -> exit"; exit 0
  fi
fi
echo "$$" > "${LOCK_DIR}/pid"
# Release the lock even if we die before the main finish trap is installed.
trap 'rmdir "${LOCK_DIR}" 2>/dev/null || rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT
```

(c) `finish` 定義の直前に breaker 用の定数を置き、`finish` を連続失敗カウンタ＋サーキットブレーカ付きへ置換:
```bash
FAILCOUNT_FILE="${STATE_DIR}/consecutive_failures"
MAX_FAILS="$(cfg maxConsecutiveFailures 5)"
finish() {
  local status=$?
  rm -f "${RUN_DIR}/.in_progress"
  if [[ "${status}" -eq 0 ]]; then
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${RUN_DIR}/.complete"
    rm -f "${FAILCOUNT_FILE}"
  else
    echo "status=${status}" > "${RUN_DIR}/.failed"
    local n; n="$(cat "${FAILCOUNT_FILE}" 2>/dev/null || echo 0)"; n=$((n + 1))
    echo "${n}" > "${FAILCOUNT_FILE}"
    if [[ "${n}" -ge "${MAX_FAILS}" ]]; then
      date -u +"%Y-%m-%dT%H:%M:%SZ" > "${STATE_DIR}/PAUSED"
      log "consecutive failures ${n} >= ${MAX_FAILS} -> circuit breaker PAUSED"
    fi
  fi
  rmdir "${LOCK_DIR}" 2>/dev/null || rm -rf "${LOCK_DIR}" 2>/dev/null || true
}
trap finish EXIT
```
（注：`trap finish EXIT` が (b) の暫定 trap を置換する。finish もロックを解放するので窓は塞がる。）

- [ ] **Step 4: 成功確認** — Run: `bash Tests/perpetual/test_cycle_daemon.sh` → PASS。続けて既存を回帰: `bash Tests/perpetual/test_cycle_offline.sh`（8/8）, `bash Tests/perpetual/test_config.sh`。

- [ ] **Step 5: コミット**
```bash
git add scripts/run_discovery_cycle.sh config/worker.json Tests/perpetual/test_config.sh Tests/perpetual/test_cycle_daemon.sh
git commit -m "feat(worker-m2): pidless-lock reclaim, lock-release trap, PAUSED circuit breaker"
```

---

### Task 2: launchd plist ＋ `discovery_agent.sh`

**Files:** Create `scripts/discovery_agent.sh`, `launchd/.gitkeep`; Create `Tests/perpetual/test_agent.sh`.

**Interfaces:** `discovery_agent.sh generate <out.plist>`（plist を書くだけ・テスト用）, `install`（生成→`~/Library/LaunchAgents/` へ→`launchctl load`）, `uninstall`（`launchctl bootout`/`unload`）, `status`, `resume`（`state/PAUSED` と `state/consecutive_failures` を削除）。

- [ ] **Step 1: 失敗するテスト**

`Tests/perpetual/test_agent.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="${ROOT}/scripts/discovery_agent.sh"

# generate a plist and validate it (no launchctl load in tests)
TMP="$(mktemp -d)"; PLIST="$TMP/com.biolab.discovery.plist"
bash "$AGENT" generate "$PLIST"
plutil -lint "$PLIST" >/dev/null || { echo "FAIL: plist not valid"; exit 1; }
grep -q '<key>KeepAlive</key>' "$PLIST" || { echo "FAIL: no KeepAlive"; exit 1; }
grep -q '<key>ThrottleInterval</key>' "$PLIST" || { echo "FAIL: no ThrottleInterval"; exit 1; }
grep -q 'run_discovery_cycle.sh' "$PLIST" || { echo "FAIL: plist does not invoke the cycle"; exit 1; }
grep -q '<key>Label</key>' "$PLIST" || { echo "FAIL: no Label"; exit 1; }

# resume clears PAUSED + failure streak
S="$(mktemp -d)"; mkdir -p "$S/state"; : > "$S/state/PAUSED"; echo 3 > "$S/state/consecutive_failures"
STATE_DIR="$S/state" bash "$AGENT" resume
[[ ! -f "$S/state/PAUSED" ]] || { echo "FAIL: resume left PAUSED"; exit 1; }
[[ ! -f "$S/state/consecutive_failures" ]] || { echo "FAIL: resume left failcount"; exit 1; }

echo "agent tests OK"
```

- [ ] **Step 2: 失敗確認** — Run: `bash Tests/perpetual/test_agent.sh` → FAIL（スクリプト不在）。

- [ ] **Step 3: 実装**

`scripts/discovery_agent.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-${ROOT_DIR}/config/worker.json}"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/state}"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
LABEL="com.biolab.discovery"
PLIST_INSTALLED="${HOME}/Library/LaunchAgents/${LABEL}.plist"

cfg() { python3 -c "import json;print(json.load(open('${CONFIG}')).get('$1','$2'))"; }

gen_plist() {  # $1 = output path
  local out="$1"
  local throttle; throttle="$(cfg throttleSeconds 300)"
  mkdir -p "$(dirname "${out}")" "${LOG_DIR}"
  cat > "${out}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${ROOT_DIR}/scripts/run_discovery_cycle.sh</string>
  </array>
  <key>WorkingDirectory</key><string>${ROOT_DIR}</string>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>${throttle}</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/daemon.out.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/daemon.err.log</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST
}

case "${1:-}" in
  generate) gen_plist "${2:?usage: generate <out.plist>}"; echo "wrote ${2}" ;;
  install)
    gen_plist "${PLIST_INSTALLED}"
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "${PLIST_INSTALLED}"
    echo "installed + loaded ${LABEL} (throttle=$(cfg throttleSeconds 300)s). Stop: scripts/discovery_agent.sh uninstall" ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    rm -f "${PLIST_INSTALLED}"
    echo "unloaded + removed ${LABEL}" ;;
  status)
    echo "label=${LABEL}"
    launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null | grep -E 'state =|pid =' || echo "not loaded"
    [[ -f "${STATE_DIR}/PAUSED" ]] && echo "PAUSED=yes (resume to clear)" || echo "PAUSED=no"
    bash "${ROOT_DIR}/scripts/discovery_status.sh" ;;
  resume)
    rm -f "${STATE_DIR}/PAUSED" "${STATE_DIR}/consecutive_failures"
    echo "resumed (cleared PAUSED + failure streak)" ;;
  *) echo "usage: $0 {generate <out.plist>|install|uninstall|status|resume}" >&2; exit 2 ;;
esac
```
`chmod +x scripts/discovery_agent.sh`。`launchd/.gitkeep` を作成。

- [ ] **Step 4: 成功確認** — Run: `bash Tests/perpetual/test_agent.sh` → PASS。

- [ ] **Step 5: コミット**
```bash
chmod +x scripts/discovery_agent.sh
git add scripts/discovery_agent.sh Tests/perpetual/test_agent.sh launchd/.gitkeep
git commit -m "feat(worker-m2): launchd agent (generate/install/uninstall/status/resume)"
```

---

### Task 3: run_all 統合 ＋ README

**Files:** Modify `Tests/perpetual/run_all.sh`, `README.md`.

- [ ] **Step 1: run_all に追加** — `test_cycle_daemon.sh` と `test_agent.sh` を `run_all.sh` に追記（`test_status.sh` の後、`ALL M1 TESTS PASSED` echo の前）。marker は `ALL M1+M2 TESTS PASSED` に更新。

- [ ] **Step 2: 全テスト成功** — Run: `bash Tests/perpetual/run_all.sh` → `ALL M1+M2 TESTS PASSED`。

- [ ] **Step 3: README 追記**（M1 セクションの後に）:
```markdown
## Perpetual Discovery Worker (M2, daemon)

Run the offline cycle continuously via launchd (back-to-back, min spacing
`throttleSeconds`). Falls back to the same guardrails; N consecutive failures
(`maxConsecutiveFailures`) trip a circuit breaker (`state/PAUSED`).

```sh
swift build -c release
scripts/discovery_agent.sh install     # load the launchd agent
scripts/discovery_agent.sh status      # loaded? paused? + discovery status
scripts/discovery_agent.sh resume      # clear PAUSED + failure streak
scripts/discovery_agent.sh uninstall   # true stop (unload + remove)
```

`state/STOP` pauses cycles without unloading; true stop is `uninstall`.
```

- [ ] **Step 4: コミット**
```bash
git add Tests/perpetual/run_all.sh README.md
git commit -m "test(worker-m2): run_all integration + README daemon section"
```

---

## Self-Review
- pre-M2 hardening（pidless reclaim・release trap 前倒し）→ Task 1 ✅
- サーキットブレーカ（連続失敗→PAUSED・成功でリセット）→ Task 1 ✅
- launchd 連続実行（KeepAlive＋ThrottleInterval）＋管理（install/uninstall/status/resume）→ Task 2 ✅
- 実 launchd load はテストで実行しない（plist 生成正当性＋resume を検証）→ Task 2 ✅
- 既存 M1 テスト回帰 → Task 1 Step 4 で確認。
- Placeholder/型整合: `maxConsecutiveFailures`/`throttleSeconds` は Task 1 で config＋test に追加、Task 2 の plist が `throttleSeconds` を使用。`STATE_DIR` seam が cycle/agent で一致。
