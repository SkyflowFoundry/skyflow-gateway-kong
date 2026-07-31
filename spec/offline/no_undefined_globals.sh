#!/bin/sh
# Catch the class of bug that took the gateway down: a local function that is
# CALLED but never defined. Lua silently resolves the name as a global, the
# global is nil, and every request dies at runtime with "attempt to call a nil
# value". Nothing in the offline suite noticed, because run_waves is tested with
# an injected fake and no test exercises the access phase itself.
#
# Rather than a full linter, read the compiled bytecode and list every GLOBAL the
# module reads. That set should contain only the standard library plus the two
# runtime injections (kong, ngx). Anything else is a typo or a deleted local.
set -eu
FILE="${1:-plugin/kong/plugins/skyflow-deidentify/handler.lua}"
ALLOWED="io ipairs kong math next ngx pairs pcall require setmetatable string table tonumber tostring type select error unpack os assert rawget rawset getmetatable tonumber print"

globals=$(luajit -bl "$FILE" 2>/dev/null | awk '/GGET/ {print $NF}' | tr -d '"' | sort -u)
if [ -z "$globals" ]; then
  echo "FAIL: could not read bytecode from $FILE" >&2
  exit 1
fi

rc=0
for g in $globals; do
  case " $ALLOWED " in
    *" $g "*) ;;
    *)
      echo "FAIL: '$g' is read as a GLOBAL in $FILE."
      echo "      Either it is a typo, or a local definition was deleted while a"
      echo "      call site remained. At runtime this is nil and the request dies."
      rc=1
      ;;
  esac
done
[ "$rc" -eq 0 ] && echo "ok: no undefined globals ($(echo "$globals" | wc -l | tr -d ' ') global reads, all allowlisted)"
exit "$rc"
