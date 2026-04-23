# Windows Ethernet TAP Step-4 Integration Closure

This checklist is for end-to-end validation after Step-3 implementation.

## Build

```powershell
cmake -S windows -B build/win_step4_on -DZTS_ENABLE_WINDOWS_OS_TAP=ON
cmake --build build/win_step4_on --config Debug --target zt_runtime_smoke -- /m:1
```

## One-shot join/probe/leave validation

Run with a real 16-hex network id:

```powershell
build\win_step4_on\runner\Debug\zt_runtime_smoke.exe `
  --join-network <NETWORK_ID_HEX> `
  --join-timeout-ms 90000 `
  --leave-timeout-ms 60000 `
  --require-route-bound
```

## Pass criteria

1. Join succeeds (`join ok=true`)
2. Probe reports:
   - `systemIpBound=true`
   - `systemRouteBound=true` (when `--require-route-bound` is enabled)
3. Leave succeeds (`leave ok=true`)
4. Network disappears from runtime status after leave timeout.

## Notes

- `systemRouteBound` depends on managed routes delivered by controller.
- If the network has no managed routes, do not pass `--require-route-bound`.
