#!/usr/bin/env bash
# Perf rerun + compare harness for tuannx/aws-advanced-jdbc-wrapper.
#
# Uses the UPSTREAM JMH module in benchmarks/ (do not replace it). Builds the
# shaded JMH jar, runs the 3 baseline classes, and diffs scores against
# perf/baseline.json.
#
# Verdict per benchmark (score = ns/op, higher = slower):
#   regression > 25%  -> block
#   regression > 10%  -> warn
#   improvement       -> reported as -x%
# Overall verdict = worst per-benchmark verdict.
#
# Sandbox notes (this VM): JVM egress needs the loopback proxy forwarder on
# 127.0.0.1:3129 / [::1]:3129 (see ~/workspace/tmp-perf/proxy-fwd.py); JMH
# forked VMs and Gradle workers need -Djava.net.preferIPv4Stack=true or the
# sandbox intercepts their loopback sockets. The wrapper is multi-release
# (8/11/17), so Gradle toolchain paths for JDK 8/11/17/21 must be registered
# in $GRADLE_USER_HOME/gradle.properties (org.gradle.java.installations.paths).
set -euo pipefail
cd "$(dirname "$0")/.."

export JAVA_HOME="${JAVA_HOME:-$HOME/workspace/tools/jdk-21.0.13.1+2}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/workspace/.gradle-perflane}"
export TMPDIR="${TMPDIR:-$HOME/workspace/tmp-perf}"
export JAVA_TOOL_OPTIONS="-Djava.net.preferIPv4Stack=true"
GRADLE_BIN="${GRADLE_BIN:-$HOME/workspace/tmp-perf/gradle-8.14.7/bin/gradle}"
[ -x "$GRADLE_BIN" ] || GRADLE_BIN="./gradlew"

mkdir -p "$TMPDIR" perf

# Start the loopback proxy forwarder if nothing listens on 3129.
if ! python3 -c "import socket;s=socket.socket();s.settimeout(2);s.connect(('127.0.0.1',3129))" 2>/dev/null; then
  echo "starting proxy forwarder..."
  (cd "$HOME/workspace/tmp-perf" && setsid nohup python3 proxy-fwd.py > proxy-fwd.log 2>&1 < /dev/null &) || true
  sleep 1
fi

"$GRADLE_BIN" :benchmarks:jmhJar \
  -Dorg.gradle.jvmargs="-Xmx2g -Djava.net.preferIPv4Stack=true" \
  --console=plain --no-daemon

JAR=$(ls benchmarks/build/libs/benchmarks-*-jmh.jar | head -1)
OUT="perf/jmh-raw-$(date +%F).json"
"$JAVA_HOME/bin/java" -jar "$JAR" \
  "ConnectionUrlParserBenchmarks|HostSelectorBenchmarks|RdsUtilsBenchmarks" \
  -f 1 -wi 3 -i 5 -rf json -rff "$OUT"

python3 - "$OUT" <<'PYEOF'
import json, sys
raw = json.load(open(sys.argv[1]))
base = json.load(open('perf/baseline.json'))['benchmarks']
cur = {}
for r in raw:
    parts = r['benchmark'].split('.')
    cur[parts[-2] + '.' + parts[-1]] = r['primaryMetric']['score']
worst = 'pass'
print(f"{'benchmark':58s} {'baseline':>10s} {'current':>10s} {'delta%':>8s}  verdict")
for name in sorted(base):
    if name not in cur:
        print(f"{name:58s} MISSING in current run"); worst = 'block'; continue
    b, c = base[name]['score_ns_per_op'], cur[name]
    d = (c - b) / b * 100.0
    v = 'pass'
    if d > 25: v = 'block'
    elif d > 10: v = 'warn'
    if v == 'block' or (v == 'warn' and worst == 'pass'): worst = v
    note = f"improvement {-d:.1f}%" if d < -0.05 else ""
    print(f"{name:58s} {b:10.3f} {c:10.3f} {d:+8.1f}  {v} {note}")
print("OVERALL VERDICT:", worst)
sys.exit(2 if worst == 'block' else 1 if worst == 'warn' else 0)
PYEOF
