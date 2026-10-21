#!/bin/bash
# EditConfig.command — opens the NVR config and every camera config in TextEdit.
# Save, then Start.command (or Test.command). A restart is required for changes to apply.
set -u
. "$(dirname "$0")/lib.sh"
mkdir -p "$CAMDIR"
[ -f "$ENV_FILE" ] || { cp "$PROJECT_DIR/.env.example" "$ENV_FILE"; chmod 600 "$ENV_FILE"; echo "created $ENV_FILE"; }
open -e "$ENV_FILE"
n=0
for f in "$CAMDIR"/*.env; do [ -f "$f" ] || continue; case "$(basename "$f")" in example-*) continue;; esac; open -e "$f"; n=$((n+1)); done
echo "opened $ENV_FILE and $n camera file(s) in $CAMDIR"
[ "$n" -eq 0 ] && echo "No cameras yet: copy $CAMDIR/example-tapo.env to $CAMDIR/<name>.env and edit it."
echo "After saving: Probe.command to verify, then Test.command / Start.command."
