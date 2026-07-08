#!/bin/bash
set -e

# if the running uid is not in /etc/passwd, create it
# This is required for OpenShift compatibility
if ! whoami &> /dev/null; then
  if [ -w /etc/passwd ]; then
    echo "Mapping arbitrary UID $(id -u) to frappe user in /etc/passwd"
    # Standard OpenShift pattern: map current UID to the 'frappe' account or create a new one
    # Here we append a new entry for the current UID with the name of the user (or 'frappe')
    echo "${USER_NAME:-frappe}:x:$(id -u):0:${USER_NAME:-frappe} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo "Warning: /etc/passwd is not writable. Cannot map UID $(id -u)."
  fi
fi

echo "Current User: $(id -u), Group: $(id -g)"
echo "Home Directory: ${HOME}"

exec "$@"
