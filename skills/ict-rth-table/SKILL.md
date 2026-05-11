---
name: ict-rth-table
description: Runs the ICT RTH aggregation table for a symbol — shows rolling 30-day baselines for session volume, daily volume, money spent, directional bias, and volatility/RSI for each of the last 20 trading days. Highlights anomalies. Usage: /ict-rth-table XAUUSD
---

Run the ICT RTH aggregation table for symbol from $ARGUMENTS.

Parse $ARGUMENTS as:
- First word = SYMBOL (e.g. XAUUSD, GOLD.f, XAUUSDp — default XAUUSD)

1. **Navigate to the AlgoPure signal lab**:
```bash
cd /c/Users/kellw/OneDrive/Custom-AlgoPure/algopure-signal-lab
```

2. **Run the analysis** (fetches 3M of M30 data to build 30-day rolling baselines + 20-day display window):
```bash
python -u -c "
import sys
import MetaTrader5 as mt5
import pandas as pd

from config          import LabConfig
from fetcher         import fetch_ohlcv
from market_analysis import compute_ict_sessions, compute_rsi

SYMBOL = 'SYMBOL_HERE'

cfg = LabConfig(symbol=SYMBOL)

if not mt5.initialize():
    print(f'MT5 init failed: {mt5.last_error()}')
    sys.exit(1)

try:
    print(f'Fetching {SYMBOL} M30 — 3M (for 30-day rolling baselines)...')
    df = fetch_ohlcv(cfg, '3M')
    print(f'  {len(df):,} bars loaded  ({df[\"time\"].iloc[0].date()} → {df[\"time\"].iloc[-1].date()})')

    result = compute_ict_sessions(
        df,
        rth_start_h  = cfg.rth_start_h,
        rth_end_h    = cfg.rth_end_h,
        n_days       = 20,
        rolling_days = 30,
    )

    # Print table header
    hdr = (
        f'{'Date':<12} {'SessVol':>10} {'30dSess':>10} {'%vSess':>7} '
        f'{'DailyVol':>10} {'30dDaily':>10} {'%vDaily':>8} '
        f'{'MoneySpent':>13} {'%Buy':>6} {'%Sell':>6} '
        f'{'AvgRSI':>7} {'Volat':>5}  Anomalies'
    )
    sep = '-' * len(hdr)
    print()
    print('  ICT RTH SESSION TABLE  [Last 20 Days — 30-day Rolling Baselines]')
    print(f'  {sep}')
    print(f'  {hdr}')
    print(f'  {sep}')

    for _, row in result.iterrows():
        flag = '*** ' if row['anomaly'] else '    '
        vs   = f\"{row['vs_sess_pct']:.0f}%\"  if not pd.isna(row.get('vs_sess_pct'))  else '—'
        vd   = f\"{row['vs_daily_pct']:.0f}%\" if not pd.isna(row.get('vs_daily_pct')) else '—'
        sb   = f\"{row['sess_baseline']:,.0f}\"  if not pd.isna(row.get('sess_baseline'))  else '—'
        db   = f\"{row['daily_baseline']:,.0f}\" if not pd.isna(row.get('daily_baseline')) else '—'
        print(
            f'  {flag}{str(row[\"date\"]):<12} '
            f'{row[\"sess_vol\"]:>10,.0f} {sb:>10} {vs:>7} '
            f'{row[\"daily_vol\"]:>10,.0f} {db:>10} {vd:>8} '
            f'{row[\"money_spent\"]:>13,.0f} '
            f'{row[\"pct_buy\"]:>5.1f}% {row[\"pct_sell\"]:>5.1f}% '
            f'{row[\"avg_rsi\"]:>7.1f} {row[\"volat_lbl\"]:>5}  {row[\"anomaly\"]}'
        )

    print(f'  {sep}')
    print()

    # Anomaly digest
    anomalous = result[result['anomaly'].str.len() > 0]
    if not anomalous.empty:
        print('  ANOMALY DIGEST:')
        for _, row in anomalous.iterrows():
            print(f'    {row[\"date\"]}  →  {row[\"anomaly\"]}')
    else:
        print('  No anomalies detected in the last 20 days.')

finally:
    mt5.shutdown()
"
```

3. **Interpret the output**:

| Column | Meaning |
|---|---|
| `SessVol` | Total tick_volume across all RTH bars that day |
| `30dSess` | 30-day rolling mean of SessVol (what's normal for the RTH session) |
| `%vSess` | SessVol / 30d session baseline × 100  — 100% = exactly average |
| `DailyVol` | Total tick_volume across ALL bars that day (24h) |
| `30dDaily` | 30-day rolling mean of DailyVol |
| `%vDaily` | DailyVol / 30d daily baseline × 100 |
| `MoneySpent` | Σ(tick_volume × close) for RTH bars — proxy for capital deployed |
| `%Buy / %Sell` | % of RTH bars closing up / down — directional bias |
| `AvgRSI` | Mean RSI(14) across all RTH bars that day |
| `Volat` | HIGH/NORM/LOW — avg range_pct vs 30-day rolling ± 1.5σ |
| `Anomalies` | Metrics that deviated > 1.5σ from 30-day rolling baseline |
| `*** row` | Day flagged with at least one anomaly |

**Anomaly codes:**
- `sess_vol↑(+2.3σ)` — RTH session volume 2.3 std above 30-day mean (unusually active)
- `sess_vol↓(-1.8σ)` — RTH session volume unusually quiet
- `BUYER_DOM` / `SELLER_DOM` — ≥ 70% of RTH bars closed in one direction
- `RSI↑(72)` / `RSI↓(28)` — overbought / oversold during session
- `VOL↑` / `VOL↓` — range-based volatility anomaly

**Key RTH time windows** (UTC — adjust per instrument/timezone):
- Gold (XAUUSD): RTH = 13:30–20:00 UTC (COMEX floor open)
- US Equities (NQ/ES): RTH = 14:30–21:00 UTC

**What to look for:**
- `sess_vol↑` + `BUYER_DOM` on same day = institutional accumulation / distribution spike
- `sess_vol↓` + low `MoneySpent` = thin market / range day, avoid directional trades
- `VOL↑` + `RSI↑(>70)` = extended move, watch for reversal next session
- Consecutive `sess_vol↓` → `sess_vol↑` spike = coil compression breakout setup
- `MoneySpent` elevated but `SessVol` normal = large average trade size (institutional flow)
