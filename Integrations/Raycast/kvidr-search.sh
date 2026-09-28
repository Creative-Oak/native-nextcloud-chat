#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Find Conversation
# @raycast.mode silent
# @raycast.packageName kvidr
# @raycast.argument1 { "type": "text", "placeholder": "Name or words" }

# Optional parameters:
# @raycast.icon 🔎
# @raycast.description Filters kvidr's sidebar to the conversations that match.

source "$(dirname "$0")/_kvidr-link.sh"
open "kvidr://search?q=$(kvidr_encode "$1")"
