# DEV-TrendTouchPoints

MetaTrader 5 Expert Advisor implementing **Tori Trade's Trendline Strategy** (`Trendline Touchpoints Playbook.pdf`), with two optional filters layered on top:

- **Slot Market-Char** filter — restrict entries to favored UTC hour windows.
- **ICT RTH** filter — restrict entries to a regular-session window.

## Files

| File | Purpose |
|---|---|
| `trendtouchpoints-mq5-ea/TrendTouchpoints_v1.00.mq5` | The EA — H4 swing strategy |
| `Trendline Touchpoints Playbook.pdf` | Source playbook |
| `AGENT.md` | Cross-agent project reference |

## Strategy summary

Three setups, all on **H4**:

1. **Bounce** — ascending line (longs) / descending line (shorts) with ≥ `InpBounceMinTouches` touchpoints and ≥ 1 week from first touch. Enter when last closed bar's wick touches the line and the close *respects* it. SL = the line itself + ATR buffer.
2. **Break (2-touchpoint)** — line broken on a confirmed close. Safety line = opposing trendline. Higher risk.
3. **Break (3-touchpoint)** — same as above but the action line has ≥ 3 touchpoints. Lower risk.

For breaks, the playbook requires the break to happen **close to the safety line** — enforced via `InpMaxBreakDistanceATR` (default 2× ATR).

## Risk management (per playbook)

- Stop = safety line ± `InpStopBufferATR × ATR` (gives wick room).
- Trail stop along the safety line each new bar.
- Exit immediately on a **bar close** through the safety line.

## Filters

### Slot filter (`InpUseSlotFilter`)
A whitelist of UTC start-hours for the H4 bar. Default `"8,12,16,20"` covers the four H4 bars that align with London-AM / NY-open / NY-PM / Asia open. Empty string = allow all hours.

### ICT RTH filter (`InpUseRTHFilter`)
Only enter when the H4 bar's start hour is inside `[InpRTHStartHourUTC, InpRTHEndHourUTC)`.

| Instrument | RTH (UTC) |
|---|---|
| Gold (XAUUSD) | 13–20 |
| US equity index (USTEC / ES / NQ) | 14–21 |

> **Server-time caveat:** `iTime()` returns broker server time. Most brokers run UTC+2 / UTC+3. Shift the RTH inputs accordingly (e.g. for a UTC+3 broker, Gold RTH = 16–23).

## Build / deploy

The EA has already been copied to:

```
C:\Users\kellw\AppData\Roaming\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts\TrendTouchpoints_v1.00.mq5
```

To re-deploy after edits:

```bash
cp trendtouchpoints-mq5-ea/TrendTouchpoints_v1.00.mq5 \
   "/c/Users/kellw/AppData/Roaming/MetaQuotes/Terminal/D0E8209F77C8CF37AD8BF550E51FF075/MQL5/Experts/"
```

## Backtest in MT5 Strategy Tester

1. Open MetaTrader 5 → **Navigator** → **Expert Advisors** → right-click `TrendTouchpoints_v1.00` → **Compile** (verify *0 errors, 0 warnings* in the Journal tab).
2. **View → Strategy Tester** (Ctrl+R).
3. Configure:
   - **Expert**: `TrendTouchpoints_v1.00`
   - **Symbol**: e.g. `XAUUSD` (playbook examples used metals + crude)
   - **Period**: `H4` (matches `InpTF`)
   - **Date**: at least 2 years for meaningful sample
   - **Modelling**: *Every tick based on real ticks* (or *1 minute OHLC* for speed)
   - **Deposit**: 10000 USD
4. Click **Start**.

### Suggested optimization passes

| Parameter | Range | Step |
|---|---|---|
| `InpFractalLeft` / `InpFractalRight` | 2 – 5 | 1 |
| `InpTouchToleranceATR` | 0.20 – 0.60 | 0.05 |
| `InpStopBufferATR` | 0.10 – 0.50 | 0.05 |
| `InpMaxBreakDistanceATR` | 1.0 – 3.0 | 0.25 |
| `InpRiskPercent` | 0.25 – 1.5 | 0.25 |

Run with `InpUseSlotFilter = false` first (baseline), then `true` to measure the slot filter's incremental edge. Same for `InpUseRTHFilter`.

## Versioning

Bump `#property version` and the filename minor on filter/rule changes (per `AGENT.md` PR checklist).
