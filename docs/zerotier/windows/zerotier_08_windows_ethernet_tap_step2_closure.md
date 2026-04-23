# Windows Ethernet TAP Step-2 Closure

This note defines what is considered "Step-2 closed" for the current integration branch.

## Scope

Step-2 only closes source/build integration and safety guards. It does **not** switch runtime host networking from `VirtualTap` to `WindowsEthernetTap` yet.

## Closed items

1. `NodeService` uses a single tap creation entry: `createNetworkTap(...)`.
2. Windows build flag added: `ZTS_ENABLE_WINDOWS_OS_TAP` (default `FALSE`).
3. When the flag is `ON`, Windows OS TAP sources are included in build:
   - `osdep/EthernetTap.cpp`
   - `osdep/WindowsEthernetTap.cpp`
   - `osdep/WinDNSHelper.cpp`
4. Windows extra libraries for OS TAP path are linked with SDK-path fallback to bare library names.
5. `VirtualTap` implements required `EthernetTap` virtual interface members for compatibility compile.
6. `NodeService` now has null-safety checks for missing `nwc` / `nuptr` in `UP` and `CONFIG_UPDATE` paths.
7. Runtime logs show current Windows mode:
   - `mode=virtualtap_compat` (default)
   - `mode=os_tap_sources_enabled_virtualtap_compat` (flag on)

## Build smoke commands

From repo root:

```powershell
cmake -S windows -B build/win_step2_off
cmake --build build/win_step2_off --config Debug --target zt-shared -j 8

cmake -S windows -B build/win_step2_on -DZTS_ENABLE_WINDOWS_OS_TAP=ON
cmake --build build/win_step2_on --config Debug --target zt-shared -j 8
```

## Exit criteria for Step-2

- Both OFF/ON builds pass for `zt-shared`.
- No compile errors from OS TAP sources when ON.
- Runtime mode log is visible for Windows tap factory path.

## Next step

Step-3 should perform real runtime host adapter bring-up using `WindowsEthernetTap` (not compatibility mode).
