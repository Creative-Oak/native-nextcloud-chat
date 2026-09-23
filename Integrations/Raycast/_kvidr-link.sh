#!/bin/bash
# Shared by the kvidr Script Commands: percent-encodes an argument for a kvidr:// link.
# Perl is on every Mac; it encodes byte by byte, which is what UTF-8 in a URL wants.
kvidr_encode() {
  printf '%s' "$1" | perl -pe 's/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/seg'
}
