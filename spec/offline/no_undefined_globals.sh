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
set -u
# Globals that exist in a NORMAL Kong runtime.
ALLOWED="io ipairs kong math next ngx pairs pcall require setmetatable string table tonumber tostring type select error unpack os assert rawget rawset getmetatable print"

# Globals the UNTRUSTED-LUA SANDBOX withholds. This plugin is streamed from the
# control plane, so its handler runs sandboxed and every one of these is nil at
# runtime even though it is perfectly valid Lua. `setmetatable` cost us a
# production outage exactly this way: the request leg de-identified fine, the
# response reached the provider, and then the SSE emitter died with
#   "attempt to call global 'setmetatable' (a nil value)"
# and fail-closed turned it into a 502 on every single request.
#
# Use the alternatives instead:
#   setmetatable({}, cjson.array_mt) -> cjson.empty_array
#   io.*                             -> guard with `if not io` and degrade
SANDBOX_FORBIDDEN="setmetatable getmetatable rawget rawset rawequal rawlen os io dofile loadfile load loadstring collectgarbage newproxy"

check_file() {
FILE="$1"
globals=$(luajit -bl "$FILE" 2>/dev/null | awk '/GGET/ {print $NF}' | tr -d '"' | sort -u)
if [ -z "$globals" ]; then
  # An empty global set is ambiguous: it means either "reads no globals" or
  # "luajit could not compile this". Distinguish them, or a broken toolchain
  # reads as a pass.
  if luajit -bl "$FILE" >/dev/null 2>&1; then
    echo "ok: $FILE reads no globals at all"
    return 0
  fi
  echo "FAIL: could not read bytecode from $FILE" >&2
  return 1
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
      continue
      ;;
  esac
  # Valid Lua, but nil when this plugin is STREAMED and therefore sandboxed.
  case " $SANDBOX_FORBIDDEN " in
    *" $g "*)
      # `io` is read behind an `if not io` guard, which is the sanctioned pattern.
      if [ "$g" = "io" ] && grep -q "if not io or not io.open then" "$FILE"; then
        echo "note: '$g' is used but guarded for the sandbox -- ok"
        continue
      fi
      echo "FAIL: '$g' is not available in the untrusted-Lua sandbox, and this"
      echo "      plugin is streamed from the control plane, so it runs sandboxed."
      echo "      It will be nil at runtime. Use the documented alternative"
      echo "      (e.g. cjson.empty_array instead of setmetatable+array_mt), or"
      echo "      guard the call and degrade."
      rc=1
      ;;
  esac
done
[ "$rc" -eq 0 ] && echo "ok: no undefined globals in $FILE ($(echo "$globals" | wc -l | tr -d ' ') global reads, all allowlisted)"
return "$rc"
}

# BOTH streamed files, not just the handler. schema.lua is uploaded to the control
# plane and evaluated in the SAME sandbox, so a forbidden global there fails the
# whole config load -- and the symptom (the data plane rejecting the config, or a
# P309) looks nothing like a Lua error in a schema.
if [ "$#" -gt 0 ]; then
  FILES="$*"
else
  FILES="plugin/kong/plugins/skyflow-ai-data-control/handler.lua plugin/kong/plugins/skyflow-ai-data-control/schema.lua"
fi

overall=0
for f in $FILES; do
  check_file "$f" || overall=1
done
exit "$overall"
