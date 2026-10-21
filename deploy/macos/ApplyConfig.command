#!/bin/bash
# ApplyConfig.command — copies the pre-filled config from config-staging/ (this folder) into the
# live config dir (~/Library/Application Support/reolink-unifi-protect), then opens every file in
# TextEdit so you can add the passwords. Existing live files are backed up as *.bak first.
set -u
. "$(dirname "$0")/lib.sh"
STAGE="$PROJECT_DIR/config-staging"
[ -d "$STAGE" ] || die "no config-staging folder next to this script"
mkdir -p "$CAMDIR"
copy_one() {  # src dst — staged file wins, except keys left EMPTY in staging keep the live value
  local src="$1" dst="$2" tmp
  if [ -f "$dst" ]; then
    cp "$dst" "$dst.bak"
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        [A-Z_]*=)  # KEY= with no value: take the live value if it has one
          k="${line%=}"; live="$(sed -n "s/^$k=//p" "$dst" | head -1)"
          [ -n "$live" ] && line="$k=$live";;
      esac
      printf '%s\n' "$line"
    done < "$src" > "$tmp"
    mv "$tmp" "$dst" && chmod 600 "$dst" && echo "  updated $dst (passwords kept, old copy in $(basename "$dst").bak)"
  else
    cp "$src" "$dst" && chmod 600 "$dst" && echo "  installed $dst"
  fi
}
say "applying config"
[ -f "$STAGE/nvr.env" ] && copy_one "$STAGE/nvr.env" "$ENV_FILE"
for f in "$STAGE"/cameras/*.env; do [ -f "$f" ] && copy_one "$f" "$CAMDIR/$(basename "$f")"; done
say "opening in TextEdit — fill in every empty PASS line, save, close"
open -e "$ENV_FILE"
for c in $(list_cameras); do open -e "$CAMDIR/$c.env"; done
echo "cameras: $(list_cameras | tr '\n' ' ')"
echo "Then: Probe.command"
