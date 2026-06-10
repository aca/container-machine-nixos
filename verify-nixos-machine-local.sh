#!/usr/bin/env bash
set -euo pipefail

# Verify the locally loaded Apple container-machine NixOS image by creating a
# disposable machine, running user/root checks, and deleting it afterward.

image_ref="${IMAGE_REF:-local/nixos-machine:latest}"
machine_name="${MACHINE_NAME:-nixos-local-test}"
expected_user="${EXPECTED_USER:-$(id -un)}"
keep_machine="${KEEP_MACHINE:-0}"
run_retries="${RUN_RETRIES:-5}"
run_retry_delay="${RUN_RETRY_DELAY:-2}"

die() {
  echo "error: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

machine_run() {
  local attempt
  local output
  local status

  for attempt in $(seq 1 "$run_retries"); do
    output="$(mktemp)"
    if container machine run "$@" >"$output" 2>&1; then
      cat "$output"
      rm -f "$output"
      return 0
    fi

    status=$?
    if [ "$attempt" = "$run_retries" ]; then
      cat "$output" >&2
      rm -f "$output"
      return "$status"
    fi

    rm -f "$output"
    echo "machine run failed; retrying in ${run_retry_delay}s ($attempt/$run_retries)" >&2
    sleep "$run_retry_delay"
  done
}

cleanup() {
  if [ "$keep_machine" = "1" ]; then
    echo "Keeping test machine: $machine_name"
    return
  fi

  if container machine inspect "$machine_name" >/dev/null 2>&1; then
    echo "Deleting test machine: $machine_name"
    container machine delete "$machine_name" >/dev/null
  fi
}

trap cleanup EXIT

need container

container image inspect "$image_ref" >/dev/null ||
  die "image is not loaded: $image_ref"

if container machine inspect "$machine_name" >/dev/null 2>&1; then
  echo "Deleting existing test machine: $machine_name"
  container machine delete "$machine_name" >/dev/null
fi

echo "Creating test machine: $machine_name"
container machine create "$image_ref" --name "$machine_name" >/dev/null

user_check='set -eu; user="$(id -un)"; uid="$(id -u)"; passwd_entry="$(getent passwd "$uid")"; echo "user=$user"; echo "uid=$uid"; echo "passwd=$passwd_entry"; command -v id; command -v getent; test -x /etc/machine/create-user.sh; test -x /etc/machine/shell; test "$user" = "$EXPECTED_USER"; case "$passwd_entry" in "$EXPECTED_USER":x:*:/etc/machine/shell) : ;; *) echo "unexpected passwd entry: $passwd_entry" >&2; exit 1 ;; esac'

root_check='set -eu; uid="$(id -u)"; echo "root_uid=$uid"; command -v id; test "$uid" = 0; test -x /etc/machine/create-user.sh'

echo "Running user checks"
machine_run -n "$machine_name" -w / \
  -e "EXPECTED_USER=$expected_user" \
  "$user_check"

echo "Running root checks"
machine_run -n "$machine_name" --root -w / "$root_check"

echo "Verification passed for $image_ref"
