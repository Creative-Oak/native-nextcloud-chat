#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Open Conversation
# @raycast.mode silent
# @raycast.packageName kvidr
# @raycast.argument1 { "type": "text", "placeholder": "Conversation or person" }

# Optional parameters:
# @raycast.icon 💬
# @raycast.description Opens a Nextcloud Talk conversation in kvidr, by name.

source "$(dirname "$0")/_kvidr-link.sh"
open "kvidr://open?conversation=$(kvidr_encode "$1")"
