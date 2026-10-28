#!/data/data/com.termux/files/usr/bin/bash
# Termux:Boot entry point -- autostarts ForgeHub's backend when the phone
# boots, without the owner having to open Termux and type a command.
#
# Install (run once, in Termux proper, after install.sh has provisioned the
# guest at least once):
#
#   mkdir -p ~/.termux/boot
#   cp ~/ForgeHub/packaging/android/boot/start-forgehub.sh ~/.termux/boot/
#   chmod +x ~/.termux/boot/start-forgehub.sh
#
# Then, separately and REQUIRED (Termux:Boot will not run anything without
# this, and there is no error message to explain why -- it just silently
# never fires):
#
#   1. Install the "Termux:Boot" app from F-Droid -- specifically F-Droid,
#      not the Play Store: the Play Store build is a different, often stale
#      release and is not what Termux's own documentation points at.
#   2. Open the Termux:Boot app at least once after installing it. Android
#      does not deliver the boot broadcast to an app that has never been
#      launched by the user -- this one manual launch is what registers the
#      receiver with the OS; skipping it is the single most common reason
#      "autostart" silently does nothing after a reboot.
#
# This file is deliberately a one-liner: all the actual logic (wake-lock,
# notification, the second-instance guard, the local-only bind) lives in
# start-backend.sh (Task 4), so there is exactly one place to fix a bug in
# it instead of two copies that can drift. Output is redirected to a log
# file because Termux:Boot runs this headless at boot time, before any
# terminal is attached to read stdout/stderr from.
exec bash "$HOME/ForgeHub/packaging/android/start-backend.sh" \
  >> "$HOME/forgehub-backend-boot.log" 2>&1
