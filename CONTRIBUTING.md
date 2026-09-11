# Contributing

Contributions are welcome, especially read-only compatibility reports and safety-focused
reviews.

## Ground rules

- Never weaken the device identity checks or write gate to make unsupported hardware run.
- Do not expose arbitrary register writes through the public IOCTL interface.
- Preserve the read-only-first installation flow.
- Add a focused test for every policy or recovery behavior change.
- Never commit private signing keys, PFX files, exported firmware containing personal data,
  or unredacted system logs.

## Pull requests

Run these checks from Windows PowerShell:

```powershell
.\tests\StaticChecks.ps1
.\Build-AutoLimiter.ps1
```

Driver changes should also pass a Release x64 WDK build, PREfast, and ApiValidator. A pull
request that changes writes, lifecycle recovery, permissions, or concurrency should explain
its failure mode and include independent review evidence.

