# Read-only SMC charging-key probe — 2026-10-19

Host: Mac16,12 (M4), macOS 27.0.1 (26A434). Tool: `tools/smc-readonly-probe` (Open/KeyCount/KeyAt/KeyInfo/Read/Close only, no writes). 2265 SMC keys. State during probe: AC attached, 68%, IsCharging=1, NotChargingReason=0.

Attribute bits: 0x80 R, 0x40 W, 0x10 FUNC, 0x04 ATOMIC, 0x02 PRIV_R, 0x01 PRIV_W. The W bit is metadata only, not proof that a userspace write is accepted or does what the name suggests.

| Key | Type/size | Attr | Value | Meaning |
|---|---|---|---|---|
| CH0B, CH0C, CHTE | size 0 | 0x00 | — | Placeholders. Legacy charge-inhibit keys do not exist here. |
| BCLM | size 0 | 0x00 | — | Old Intel/early-AS limit key, placeholder. |
| bfF0/bfD0/bfE0 | absent | — | — | batt firmware charge-limit mode unavailable. |
| CHIE | hex_ 1 | 0xd4 R/W | 00 | Adapter inhibit (00 = adapter enabled). Only user-writable charging key. Cutting it = Mac runs on battery. |
| CH0I | size 0 | — | — | Old adapter key, placeholder. |
| CHI1/CHI2 | ui32 | 0x95 PRIV_W | 3000 | Input current limits (mA). Private write: kernel/Apple only. |
| ACLC | ui8 | 0xd4 R/W | 04 | MagSafe LED. |
| bfB0/bfC0, bfG0, bfI0…bfL0, bfv0 | various | 0x94 R only | — | New-firmware battery keys, read-only from userspace. |

## Why the legacy loop does not apply

The legacy production loop pauses charging by writing CH0B/CH0C (or CHTE). On this Mac those keys exist only as zero-size placeholders: no read, no write, so the charge-only thermal gate has nothing to actuate. The firmware path (bfF0/bfD0/bfE0) is absent too. The daemon therefore falls to native (PowerUI) mode, where the only charge-stop mechanism is Apple's optimized/limit setting (advertised 80/85/90/95/100).

The only writable charging-related key is CHIE, which disconnects the adapter entirely. That produces exactly the rejected behaviour: Mac on battery instead of AC with charging paused.

## Remaining options for charge-only Heat Protection

1. Native limit as heat gate: when hot, set Apple limit to 80 (or current-rounded-up advertised value). Stops charging on AC only when battery ≥ that value; below 80% it cannot pause. Needs no SMC write; uses the existing native setter with readback.
2. AlDente-style preferences + CHIE pulse (static evidence in `aldente-backend-research-20261017.md`). Unproven physically on this Mac; earlier below-current limit test (36%) kept charging. Requires a supervised test with write approval.
3. Accept Apple's own thermal management (TimeChargingThermallyLimited) and show it, without custom control.
