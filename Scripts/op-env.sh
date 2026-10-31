#!/usr/bin/env bash
# Run a command with the 1Password service account token from the login keychain in its environment.
set -uo pipefail
token=$(security find-generic-password -a "${USER:-$(id -un)}" -s "${OP_KEYCHAIN_SERVICE:-op-service-account}" -w 2>/dev/null)
if [ -z "$token" ]; then
  echo "no 1Password service account token in the keychain" >&2
  exit 1
fi
OP_SERVICE_ACCOUNT_TOKEN="$token" exec "$@"
