# Sourced, not run. The machine verdict: whether the Mac has room for more work
# right now. scripts/machine.sh prints it before each new builder session, and
# scripts/lib/heavy.sh asks it before a job takes the third build slot.
#
#     verdict_pageouts               the Mac's page-outs so far
#     verdict BEFORE AFTER SECONDS   succeeds on yes; BEFORE and AFTER are two
#                                    verdict_pageouts readings SECONDS apart
#
# The verdict is no when the 5-minute load is at or over 1 per core, the Mac
# pages out 50 or more pages a second, or under 15 percent of memory is free:
# M0's flakes and 5-minute checks came at a load of 13 and more on 10 cores,
# against about 0.5 per core with four builders. A reading it can't take is a
# no, and so is a page-out rate with no BEFORE reading. LEXICON_MACHINE_VERDICT
# set to yes or no decides instead, for tests; the readings are still taken.
#
# It sets verdict_cores, verdict_load5, verdict_per_core, verdict_rate,
# verdict_free and verdict_why (the reasons for a no, joined by "; ").

verdict_pageouts() { vm_stat | awk '/^Pageouts:/ { gsub(/\./, "", $2); print $2 }'; }

verdict_add() { verdict_why="$verdict_why${verdict_why:+; }$1"; }

verdict() {
    verdict_before=$1 verdict_after=$2 verdict_secs=$3
    set -- $(sysctl -n hw.ncpu vm.loadavg 2> /dev/null | tr -d '{}')
    verdict_cores=${1:-} verdict_load5=${3:-}
    verdict_free=$(memory_pressure -Q 2> /dev/null | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p')
    verdict_why=
    if awk -v l="$verdict_load5" -v c="$verdict_cores" 'BEGIN { exit !(c ~ /^[0-9]+$/ && c > 0 && l ~ /^[0-9.]+$/) }'; then
        verdict_per_core=$(awk -v l="$verdict_load5" -v c="$verdict_cores" 'BEGIN { printf "%.2f", l / c }')
        if awk -v p="$verdict_per_core" 'BEGIN { exit !(p >= 1) }'; then
            verdict_add "load $verdict_load5 over 5 min on $verdict_cores cores"
        fi
    else
        verdict_per_core=?
        verdict_add "load reading unknown"
    fi
    if [ -n "$verdict_before" ]; then
        verdict_rate=$(awk -v a="$verdict_before" -v b="$verdict_after" -v s="$verdict_secs" 'BEGIN { printf "%d", (b - a) / (s > 0 ? s : 1) }')
        if [ "$verdict_rate" -ge 50 ]; then verdict_add "paging out $verdict_rate pages/s"; fi
    else
        verdict_rate=?
        verdict_add "page-outs not measured yet"
    fi
    if [ -z "$verdict_free" ]; then
        verdict_add "memory reading unknown"
    elif [ "$verdict_free" -lt 15 ]; then
        verdict_add "memory $verdict_free% free"
    fi
    case "${LEXICON_MACHINE_VERDICT:-}" in
    yes) verdict_why= ;;
    no) verdict_why=${verdict_why:-LEXICON_MACHINE_VERDICT is no} ;;
    esac
    [ -z "$verdict_why" ]
}
