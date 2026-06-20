# Summon-on-activation design

Date: 2026-06-20

## Problem

Windows are easy to "lose". Example: System Settings is opened on workspace 4,
the user moves to workspace 2 and later wants Settings again. Re-triggering it
from Raycast just activates the already-running app instead of opening a new
window, and the user has to hunt for which workspace it lives on.

Paneless already has `focusFollowsApp`, which on app activation *jumps* the user
to the workspace where the app's window lives. That preserves workspace layout
but yanks the user out of their current context, which is the opposite of what
is wanted here.

## Decision

When an app is activated (Raycast / Cmd-Tab / Dock) and it has no window on the
current workspace but has window(s) parked on another workspace of the same
monitor, **pull those windows onto the current workspace** instead of jumping
away. The user stays put; the window comes to them.

This replaces the jump action of `focusFollowsApp`. No new keybinding, no new
config option (user chose a single behavior, not a configurable one).

## Behavior

- Tiled windows: inserted into the current workspace via `layoutEngine.insert`,
  then `retile()` positions them.
- Floating windows (e.g. System Settings, which is in `floatApps`): placed
  visibly on the current screen. Use the window's saved frame if it lands inside
  the current screen; otherwise center it on the current screen.
- All of the app's windows found on other workspaces of the current monitor are
  summoned (you asked for the app, you get its windows).
- Sticky windows are skipped (already visible everywhere).
- The summoned (or first summoned) window receives focus.
- Workspace state is persisted after the move.

## Implementation

- New `summonAppWindowsToCurrentWorkspace(pid:)` in `WindowManager`. It is the
  mirror of `moveToVirtualWorkspace`: instead of moving the focused window from
  the live set into a stored workspace, it moves matching windows from stored
  workspaces into the live set, un-parking them.
- In `applicationActivated(pid:name:)`, the branch that currently calls
  `switchVirtualWorkspace(wsNum)` calls `summonAppWindowsToCurrentWorkspace(pid:)`
  instead.

### Empty-workspace suppression fix

`applicationActivated` currently suppresses follow entirely when the current
workspace is empty. That guard exists for one real case: closing the last window
on a workspace makes macOS auto-activate the next app in z-order, which would
otherwise drag an unrelated window to the now-empty workspace.

Refine it: record `lastWindowDestroyedAt` in `windowDestroyed`. Suppress only
when a window was destroyed within the last ~400 ms. A genuine activation onto
an empty workspace (Raycast → System Settings) then summons correctly.

## Out of scope (v1)

- Summoning a window that lives on a *different physical monitor*. That window is
  visible on another screen, a different scenario from a parked window on a
  virtual workspace. Current-monitor scope only.
