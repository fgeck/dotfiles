# Sketchybar Freeze Analysis: AeroSpace Socket Issue

**Date:** 2026-01-15
**Symptom:** Sketchybar freezes (rainbow cursor on hover), clock stops updating

## Root Cause

The lua process opened a Unix socket connection to AeroSpace (FD 5). When `sbar.exec()` spawned child processes (`cpu_load`, `network_load`), they **inherited the socket FD** by default.

```
lua       (64322) FD 5 ─┐
network_l (64920) FD 5 ─┼──> AeroSpace FD 11 (single connection)
cpu_load  (64923) FD 5 ─┘
```

**Problem:** Multiple processes sharing one socket connection causes corruption:
- Parent sends request, child accidentally reads the response
- Socket stream gets out of sync
- Parent blocks forever waiting for data that was already consumed

## Diagnosis Steps

### 1. Confirm freeze
```bash
timeout 2 sketchybar --query bar  # Times out if frozen
```

### 2. Sample the lua process to find where it's stuck
```bash
sample $(pgrep -f "lua.*sketchybarrc") 1
```

Output showed:
```
873 Pread (in unistd.so)
  873 read (in libsystem_kernel.dylib)  # Blocked here forever
```

### 3. Check for FD inheritance
```bash
lsof -U 2>/dev/null | grep -E "lua|cpu_load|network_l"
```

Found all three processes sharing the same socket (`0x3f88d1626d98f644`).

### 4. Verify AeroSpace is responsive
```bash
timeout 2 aerospace list-workspaces --focused  # Works fine
```

AeroSpace was healthy - the socket connection was corrupted, not the server.

## Fix

### 1. FD_CLOEXEC (prevents inheritance)

Set `FD_CLOEXEC` flag on the socket immediately after creation. This tells the OS to automatically close this FD in child processes after `exec()`.

```lua
local function set_cloexec(fd)
    local flags = fcntl.fcntl(fd, fcntl.F_GETFD)
    if flags then
        fcntl.fcntl(fd, fcntl.F_SETFD, flags | fcntl.FD_CLOEXEC)
    end
end
```

### 2. Timeout with poll() (safety net)

Use `poll()` to check if data is available before `read()`. If no data arrives within 5 seconds, timeout and reconnect.

```lua
local function wait_for_data(fd, timeout_ms)
    local result = poll.rpoll(fd, timeout_ms)
    return result and result > 0
end
```

## Files Changed

- `helpers/log.lua` - New logging module
- `helpers/aerospace.lua` - Added FD_CLOEXEC, timeout, logging

## Verification

After restart, verify child processes don't have the socket:

```bash
# Lua should have the socket
lsof -p $(pgrep -f "lua.*sketchybarrc") | grep unix

# Children should NOT have it
lsof -p $(pgrep -f cpu_load),$(pgrep -f network_load) | grep unix
```

## Log File

Debug logs are written to `/tmp/sketchybar_lua.log`. Look for:
- `TIMEOUT` - Socket read timed out
- `reconnect` - Socket was reconnected after failure
- `SLOW QUERY` - Query took >500ms

## Key Learnings

1. **Unix socket FDs are inherited by child processes by default** - Always set `FD_CLOEXEC` on sockets that shouldn't be shared
2. **Blocking reads without timeout can freeze the entire event loop** - Use `poll()` before `read()`
3. **Process sampling (`sample` command on macOS) is invaluable** - Shows exactly where a process is stuck
4. **`lsof -U` shows Unix socket relationships** - The `->0x...` shows which socket endpoints are connected

---

## Additional Issue: Mach IPC Deadlock (2026-01-16)

**Symptom:** Sketchybar bar works (click events fire), but lua callbacks stop running. Clock freezes.

**Trigger:** Wake from sleep, especially when connecting to dock with monitors.

### Stack trace shows different issue

```
callback_function (in sketchybar.so) → sketchybar → mach_send_message → mach_msg2_trap
```

Both sketchybar and lua are waiting to send messages to each other - a **mach IPC deadlock**.

### Analysis

This is different from the socket issue. The sketchybar ↔ lua communication uses mach ports, and during sleep/wake with monitor changes, an event storm can cause:
- sketchybar sends event to lua
- lua callback tries to call `sbar.set()` or similar back to sketchybar
- sketchybar is still waiting for lua to finish processing
- Deadlock

### Monitoring

Event logging added to `items/workspaces.lua`:
```lua
log.debug("EVENT: aerospace_workspace_change")
log.debug("EVENT: front_app_switched")
log.debug("EVENT: display_change")
```

Check for event storms:
```bash
grep "EVENT:" /tmp/sketchybar_lua.log | tail -50
```

### Status

Root cause still under investigation. May require debouncing display_change events or restructuring callbacks to avoid synchronous calls back to sketchybar during event handling.
