#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Write Message
# @raycast.mode silent
# @raycast.packageName kvidr
# @raycast.argument1 { "type": "text", "placeholder": "To" }
# @raycast.argument2 { "type": "text", "placeholder": "Message" }

# Optional parameters:
# @raycast.icon ✍️
# @raycast.description Opens the conversation in kvidr with your message in the field, to send with Return. Links never send by themselves.

source "$(dirname "$0")/_kvidr-link.sh"
open "kvidr://compose?conversation=$(kvidr_encode "$1")&text=$(kvidr_encode "$2")"
