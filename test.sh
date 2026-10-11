#!/bin/sh
# Live-engine checks for mounts and volumes. Needs `container` (brew install container).
# usage: ./test.sh [path/to/mdocker]   (default: .build/release/mdocker)
M=${1:-$(dirname "$0")/.build/release/mdocker}
A=docker.io/library/alpine
T=$(mktemp -d); fail=0
ok() { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }
check() { name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
VOLS='container volume ls -q'
cleanup() { "$M" compose -f "$T/compose.yaml" down -v >/dev/null 2>&1
  for v in $(container volume ls -q | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-'); do echo "$ANON0" | grep -qx "$v" || container volume rm "$v" >/dev/null 2>&1; done; container volume rm mdt-ext >/dev/null 2>&1; rm -rf "$T"; }
ANON0=$(container volume ls -q | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-')
trap cleanup EXIT

echo "docker run -v"
check "missing host dir is created"      sh -c "$M run --rm -v $T/new/a:/c $A true && [ -d $T/new/a ]"
check "-v=src:dst is created too"        sh -c "$M run --rm -v=$T/new/b:/c $A true && [ -d $T/new/b ]"
check "attached -vsrc:dst works"         sh -c "$M run --rm -v$T/new/c:/c $A true && [ -d $T/new/c ]"
check ":ro is enforced"                  sh -c "! $M run --rm -v $T/new/a:/c:ro $A touch /c/x"
check ":rw is writable"                  sh -c "$M run --rm -v $T/new/a:/c:rw $A touch /c/x"
check "--mount with missing path errors" sh -c "! $M run --rm --mount type=bind,src=$T/nope,dst=/c $A true"

echo "compose"
mkdir -p "$T/src" && echo hi > "$T/src/f"
container volume create mdt-ext >/dev/null 2>&1
cat > "$T/compose.yaml" <<YAML
name: mdt
services:
  s:
    image: $A
    command: sleep 300
    volumes:
      - {type: bind, source: ./src, target: /src, read_only: true}
      - {type: volume, source: data, target: /data}
      - {type: volume, target: /anon}
      - ext:/ext
      - ./made/here:/here
    tmpfs: /scratch
volumes:
  data:
  ext: {external: true, name: mdt-ext}
YAML
C="$M compose -f $T/compose.yaml"
check "up"                               $C up
check "long-form bind is read-only"      sh -c "! container exec mdt-s touch /src/x"
check "bind source is readable"          sh -c "[ \"\$(container exec mdt-s cat /src/f)\" = hi ]"
check "missing bind dir is created"      [ -d "$T/made/here" ]
check "tmpfs is mounted"                 sh -c "container exec mdt-s df /scratch | grep -q tmpfs"
container exec mdt-s sh -c 'echo keep > /data/f' >/dev/null 2>&1
check "down keeps the named volume"      sh -c "$C down && $VOLS | grep -qx mdt_data"
check "volume data survives up"          sh -c "$C up && [ \"\$(container exec mdt-s cat /data/f)\" = keep ]"
check "down -v removes the project volume" sh -c "$C down -v && ! $VOLS | grep -qx mdt_data"
check "down -v leaves the external volume" sh -c "$VOLS | grep -qx mdt-ext"
# `down` (no -v) keeps anonymous volumes, like docker; `down -v` must remove the ones it created.
ANON="$VOLS | grep -cE '^[0-9a-f]{8}-[0-9a-f]{4}-'"
$C down -v >/dev/null 2>&1; before=$(sh -c "$ANON")
$C up >/dev/null 2>&1; during=$(sh -c "$ANON"); $C down -v >/dev/null 2>&1; after=$(sh -c "$ANON")
check "up creates an anonymous volume"   [ "$during" -gt "$before" ]
check "down -v removes anonymous volumes" [ "$after" = "$before" ]
container volume rm mdt-ext >/dev/null 2>&1
check "missing external volume errors"   sh -c "! $C up"

[ $fail = 0 ] && echo "all passed" || { echo "FAILED"; exit 1; }
