#!/bin/bash
# seqrun.sh <label> <command...>: submit one heavy job, respecting the lock's turn reservation.
# If another job holds the lock, wait for its END in /tmp/lightly-heavy.log first. On BUSY (75),
# wait for the next release and resubmit ONCE with the same label (the BUSY call reserved the
# turn). Never loops further: a second BUSY leaves the job pending (exit 75).
source "$(dirname "$0")/env.sh"
label=$1; shift
cd "$LIGHTLY_REPO" || exit 1
wait_for_release() {
  local holder
  holder=$(awk '/ START /{p=$4} / END /{if ($4==p) p=""} END{print p}' /tmp/lightly-heavy.log)
  [ -n "$holder" ] && until grep -q "END .*$holder " /tmp/lightly-heavy.log; do sleep 2; done
}
for attempt in 1 2; do
  wait_for_release
  rtk proxy scripts/heavy "$label" "$@"; rc=$?
  echo "SUBMIT $label attempt=$attempt exit=$rc"
  [ "$rc" -ne 75 ] && exit "$rc"
done
exit 75
