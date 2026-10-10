# InvertMouse
Adds the ability to invert the mouse Y-axis in games that lack this feature, such as Genshin Impact

# Usage

1. Install [Raw Accel v1.6.0](https://github.com/a1xd/rawaccel) or [Interception](https://github.com/oblitum/Interception) driver. Reboot.
2. Run [InvertMouse](https://github.com/oleg-st/InvertMouse/releases/latest)

# Requirements
[Raw Accel v1.6.0](https://github.com/a1xd/rawaccel) or [Interception](https://github.com/oblitum/Interception) driver installed. .NET Framework 4.7.2+

# How it works

InvertMouse uses kernel mode driver and library to invert mouse Y-axis when cursor is hidden. 
This allows interactions in the menu (when cursor is visible) without inverted Y-axis.

# Driver comparison
Raw Accel is [Anti-Cheat Friendly](https://github.com/a1xd/rawaccel#anti-cheat-friendly). Raw Accel has a one second delay when changing settings.  
Interception has no delay but can be detected by Vanguard and FaceIt.  
[Read more](https://www.kovaak.com/mouse-acceleration/)

# InvertMouse Driver

I wrote a separate driver for mouse inversion. It is anti-cheat friendly and has low delay when toggling inversion.

The driver package is prepared for Partner Center attestation signing and direct/test deployment. Attestation is not a Windows Update retail certification; WHCP/HLK remains required for that bar. See [docs/driver-readiness.md](docs/driver-readiness.md).

- **Driver source code:** [src/InvertMouseDriver](src/InvertMouseDriver)
- **CI binaries for signing:** [GitHub Actions](https://github.com/oleg-st/InvertMouse/actions)
- **Promote a validated SYS into the installer:** `.\scripts\promote-driver.ps1 -Platform x64`

```powershell
dotnet tool restore

# Clean rebuild, freshness check, unsigned CABs
.\scripts\Build-Release.ps1 -SkipSigning

# Same, then EV-sign SYS and CABs
.\scripts\Build-Release.ps1 -CertificateSubject "Your EV subject"

# Confirm current Release outputs are newer than driver sources
.\scripts\Test-BuildFreshness.ps1

# Sign already-staged artifacts
.\scripts\Sign-DriverPackage.ps1 -CertificateSubject "Your EV subject"
```
