# InvertMouse driver readiness

This report records the production-signing bar for the InvertMouse KMDF mouse-class upper filter after the production-readiness audit.

## Signing boundary

The package is prepared for **Partner Center attestation submission** and for **direct/test deployment** of the signed result.

Attestation-signed drivers are **not** a Windows Update retail certification. Microsoft currently documents attestation as a testing/direct-deployment path. A WHCP/HLK submission remains required for retail Windows Update publication.

Microsoft regenerates catalog files during attestation. Submit an EV-signed CAB that contains the per-architecture package in a subdirectory (`InvertMouse\`), including `InvertMouse.sys`, `InvertMouse.inf`, and `InvertMouse.pdb`. Do not package a local `.cat`; Partner Center overwrites catalogs during submission.

## What changed

- The mouse callback now snapshots settings under a spin lock and inspects every packet.
- Non-finite multipliers are rejected; movement scaling saturates to `LONG`.
- The filter device attaches as a pass-through if control-device init fails. In Safe Mode, `EvtDeviceAdd` does not attach (Microsoft filter-driver guidance) and the control device is not created.
- The control device ACL is SYSTEM + Administrators + authenticated users. IOCTLs use read/write access bits.
- The INF is a per-architecture DefaultInstall/KMDF service package. It no longer binds `HID_DEVICE_SYSTEM_MOUSE` or writes `UpperFilters`.
- `DriverInstaller` still prepends `InvertMouse` to the Mouse-class `UpperFilters` list so the filter stays below `mouclass`, and it now rolls back partial installs and deletes the SCM service on uninstall.
- CI stages SYS/INF/PDB/CAB and runs InfVerif when the WDK tools are present.

## Package layout

| File | Role |
|------|------|
| `InvertMouse.sys` | KMDF filter binary |
| `InvertMouse.inf` | Stampinf output from `InvertMouse.inx` |
| `InvertMouse.pdb` | Required for Microsoft crash analysis |
| `InvertMouseDriver_<arch>.cab` | Attestation submission container (SYS/INF/PDB; no `.cat`) |

Release packaging follows the typical Nefarius driver development style and harness: clean rebuild, refuse stale outputs, stage SYS/INF/PDB CABs, then optionally EV-sign.

```powershell
dotnet tool restore
.\scripts\Build-Release.ps1 -SkipSigning
.\scripts\Build-Release.ps1 -CertificateSubject "Your EV subject" -Version 1.0.1.0
.\scripts\Test-BuildFreshness.ps1
.\scripts\Sign-DriverPackage.ps1 -CertificateSubject "Your EV subject"
```

Signing uses `dotnet wdkwhere run signtool` and verifies with `signtool verify /pa`. Kernel policy (`/kp`) is for Microsoft attestation signatures, not the local EV publisher signature.

Promote a validated (and, for release, signed) SYS into the app installer with:

```powershell
.\scripts\promote-driver.ps1 -Configuration Release -Platform x64
.\scripts\promote-driver.ps1 -Configuration Release -Platform ARM64
```

Do not copy unsigned local build outputs into `src/DriverInstaller/driver` for a public release.

## Static and package checks

Run on a machine with the WDK:

```powershell
msbuild src\InvertMouseDriver\InvertMouseDriver.sln /p:Configuration=Release /p:Platform=x64
.\scripts\stage-driver-package.ps1 -BuildDir src\InvertMouseDriver\x64\Release\InvertMouse -Architecture x64 -OutputDir artifacts\x64
```

`scripts/verify-driver-package.ps1` checks INF topology, PE machine type, and InfVerif `/u`. InfVerif `/w` is intentionally not the gate: this class filter still installs to `%12%` (`System32\drivers`) so the existing SCM path keeps working.

### Results from this branch

| Check | x64 | ARM64 |
|-------|-----|-------|
| Release + Debug KMDF build | Pass | Pass |
| InfVerif `/u /v` (Universal) | Valid | Valid |
| InfVerif `/w /v` (Windows Driver isolation) | Fail 1322: DIRID 12, expected | Fail 1322: DIRID 12, expected |
| Staged CAB (`InvertMouse\` + SYS/INF/PDB) | Pass | Pass |
| PE machine type | `0x8664` | `0xAA64` |
| Production `signtool verify /pa` | Fail (WDK test certificate only) | Fail (WDK test certificate only) |

Local WDK `ApiValidator` was skipped with `/p:ApiValidator_Enable=false` because the x86 helper on this host returns Win32 193. Leave the project default enabled so an x64 CI agent still runs Universal DDI validation.

The InvertMouse app project still depends on the Raw Accel wrapper and was not rebuilt here. `DriverInstaller` Release compiled. `InvertMouseControl` IOCTL access bits were updated to match the driver.

## VM-only stability matrix

Do **not** enable Driver Verifier on a development host. Use a disposable VM.

| ID | Scenario | Windows | Arch | Pass criteria |
|----|----------|---------|------|----------------|
| V1 | Fresh install via `DriverInstaller` | 10 22H2, 11 24H2 | x64, ARM64 | Service exists; Mouse-class `UpperFilters` starts with `InvertMouse`; inversion works |
| V2 | Reinstall / upgrade | same | same | File replace or reboot-pending replace; filter appears once |
| V3 | Uninstall | same | same | Filter removed; service deleted or marked for delete; reboot clears `.sys` |
| V4 | Rollback of a failed install | same | x64 | Previous `UpperFilters` restored; no orphan service when install created it |
| V5 | Driver Verifier (standard + I/O) | 11 | x64 | No bugcheck during mouse motion, IOCTL storm, disable/enable |
| V6 | Rapid hide/show cursor + SET/GET | 11 | x64 | No torn settings; toggle delay remains 100 ms / 1 s |
| V7 | USB + Bluetooth mice | 11 | x64 | Both devices invert; reconnect still connects |
| V8 | Sleep/resume | 11 | x64 | Stack returns; inversion still applied |
| V9 | Device disable/re-enable | 11 | x64 | CONNECT succeeds; no sharing-violation leak after restart |
| V10 | Safe Mode | 11 | x64 | Filter does not attach; mouse stack starts; `\\.\invertmouse` is absent |
| V11 | Standard-user IOCTL | 11 | x64 | Authenticated user can GET/SET; guest/anonymous cannot |
| V12 | Invalid multipliers | 11 | x64 | NaN/Inf rejected; extreme values saturate without bugcheck |
| V13 | Secure Boot, no test signing | 11 | x64, ARM64 | Loads only with a Microsoft-trusted signature |
| V14 | pnputil / INF DefaultInstall | 11 | x64 | Files and service install; class filter still comes from `DriverInstaller` |

## Residual risks

- Attestation is not WHCP. Retail Windows Update signing still needs HLK.
- Class-filter registration remains installer-owned. A signed INF alone does not prepend `UpperFilters` ahead of `mouclass`.
- `IOCTL_INTERNAL_MOUSE_DISCONNECT` still returns `STATUS_NOT_IMPLEMENTED`, matching Microsoft Moufiltr.
- The 100–1000 ms settings delay is intentional anti-cheat behavior and holds the sequential control queue.
- Committed `src/DriverInstaller/driver/*.sys` blobs can still drift until a signed build is promoted with `promote-driver.ps1`.
- ARM64 functional tests require ARM64 hardware or an ARM64 VM; they are not implied by an x64 host build.
