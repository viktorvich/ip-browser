## What changes for a person using IP Browser

## How it was proven
<!-- the command and its output, a test, a lab hook run, a leak test screenshot -->

## Checklist
- [ ] `tools/ci.sh` passes (shellcheck, build, unit tests)
- [ ] Nothing can reach the network around LocalGate; no plain (unmasked) kind
- [ ] `Server/install.sh` changed → `tools/vm-test.sh` fresh and upgrade pass, and `uninstall` removes what was added
- [ ] User-facing text in both English and Russian
