# Pull request

## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Testing

<!-- What you ran and what it showed. For interpreter changes: which
     build variants, which test legs, CSpect or real hardware. -->

---

## Extern submission checklist

<!-- Delete this whole section if this PR does not add or change an
     extern under authoring-kit\externs\. Details: CONTRIBUTING.md -->

- [ ] Folder contains exactly the four files: source `.asm`, prebuilt
      `GAME.XBN`, `README.md`, `build.ps1`
- [ ] `powershell -File tests\audit-externs.ps1` passes locally
      (binary matches a fresh assembly, header validates, README
      documents the interface)
- [ ] fn codes are 16+ and, with every flag used, documented in the
      extern's README; no collision with the table in
      `authoring-kit\externs\README.md`, and my row is added there
- [ ] `#int` hook rules obeyed (short, no EI, no DMA, no file IO or
      services, no self-installed vectors) - or no hook is used
- [ ] Visible tilemap output stays in rows 4-27
- [ ] Tested from a clean card copy beside a real `GAME.DDB`;
      CSpect vs real-hardware coverage stated below

**Tested on:**

<!-- e.g. "CSpect 3.3.1: full cycle. Real Next (core 3.02.04, HDMI):
     arm/disarm verbs." -->
