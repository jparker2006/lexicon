#!/bin/sh
# live-lane.sh's holder on Codex: the lane names the Codex CLI process above
# the caller, so a Codex session keeps it across separate shell calls, each a
# fresh shell that ends with the call. A fake ps puts a Codex process (pid
# 424242) above this test shell; every other ps call is the lib's.
. "$(dirname "$0")/lib.sh"
LANE="$ROOT/scripts/live-lane.sh"
CODEX=424242

mv "$T/bin/ps" "$T/bin/ps.lib"
cat > "$T/bin/ps" <<EOF
#!/bin/sh
case "\$*" in
    "-o ppid= -p $$") echo $CODEX ;;
    "-o ppid= -p $CODEX") echo 1 ;;
    "-o comm= -p $CODEX") echo "$HOME/.codex/packages/standalone/current/bin/codex" ;;
    "-o lstart= -p $CODEX") echo "Tue Oct 13 09:00:00 2026" ;;
    *) exec "$T/bin/ps.lib" "\$@" ;;
esac
EOF
chmod +x "$T/bin/ps"

# Each sh -c is one shell call; the trailing : keeps it from exec'ing the script.
expect ok "codex-test holds the live-app lane \\(pid $CODEX\\)" "a Codex session's take names the Codex process" sh -c "\"$LANE\" take codex-test; :"
expect ok "^$" "a later shell call of the same Codex session still holds the lane" sh -c "\"$LANE\" check; :"
expect ok "held by codex-test \\(pid $CODEX\\)" "the lock outlives the shell call that took it" sh -c "\"$LANE\" status; :"
expect ok 'codex-test released' "the same Codex session releases it from another call" sh -c "\"$LANE\" release; :"
finish
