#!/bin/bash
# Update.command — pulls the latest code from the fork, reinstalls, restarts.
set -u
. "$(dirname "$0")/lib.sh"
"$PROJECT_DIR/Stop.command" </dev/null | grep -v "Press Return"
"$PROJECT_DIR/Install.command" </dev/null | grep -v "Press Return"
"$PROJECT_DIR/InstallService.command" </dev/null | grep -v "Press Return"
pause
