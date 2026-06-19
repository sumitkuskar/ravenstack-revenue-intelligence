# RavenStack — Trend Indicator DAX Measures
## How to add these: Home → _Measures table → New Measure → paste → Enter

---

## STEP 1 — MoM % Change Measures

### MRR MoM % Change
```dax
MRR MoM % Change =
VAR CurrentMRR = [Current Active MRR]
VAR PrevMRR =
    CALCULATE(
        [Current Active MRR],
        DATEADD('Calendar'[Date], -1, MONTH)
    )
RETURN
DIVIDE(CurrentMRR - PrevMRR, PrevMRR, 0)
```

---

### ARR MoM % Change
```dax
ARR MoM % Change =
VAR CurrentARR = [Current Active ARR]
VAR PrevARR =
    CALCULATE(
        [Current Active ARR],
        DATEADD('Calendar'[Date], -1, MONTH)
    )
RETURN
DIVIDE(CurrentARR - PrevARR, PrevARR, 0)
```

---

### ARPU MoM % Change
```dax
ARPU MoM % Change =
VAR CurrentARPU = [Current ARPU]
VAR PrevARPU =
    CALCULATE(
        [Current ARPU],
        DATEADD('Calendar'[Date], -1, MONTH)
    )
RETURN
DIVIDE(CurrentARPU - PrevARPU, PrevARPU, 0)
```

---

### Accounts MoM Change
```dax
Accounts MoM Change =
VAR CurrentAccounts = [Total Active Accounts]
VAR PrevAccounts =
    CALCULATE(
        [Total Active Accounts],
        DATEADD('Calendar'[Date], -1, MONTH)
    )
RETURN
CurrentAccounts - PrevAccounts
```
-- Note: This returns an absolute number (e.g. +8), not a percentage,
-- because "500 accounts, up 1.6%" is less useful than "up 8 accounts"

---

### Churn MoM % Change
```dax
Churn MoM % Change =
VAR CurrentChurn = [Total Churned Accounts]
VAR PrevChurn =
    CALCULATE(
        [Total Churned Accounts],
        DATEADD('Calendar'[Date], -1, MONTH)
    )
RETURN
DIVIDE(CurrentChurn - PrevChurn, PrevChurn, 0)
```

---

## STEP 2 — Trend Label Measures (the ▲ ▼ text shown on card)

### MRR Trend Label
```dax
MRR Trend Label =
VAR Change = [MRR MoM % Change]
RETURN
IF(
    Change >= 0,
    "▲ " & FORMAT(Change, "0.0%") & " MoM",
    "▼ " & FORMAT(ABS(Change), "0.0%") & " MoM"
)
```

---

### ARR Trend Label
```dax
ARR Trend Label =
VAR Change = [ARR MoM % Change]
RETURN
IF(
    Change >= 0,
    "▲ " & FORMAT(Change, "0.0%") & " MoM",
    "▼ " & FORMAT(ABS(Change), "0.0%") & " MoM"
)
```

---

### ARPU Trend Label
```dax
ARPU Trend Label =
VAR Change = [ARPU MoM % Change]
RETURN
IF(
    Change >= 0,
    "▲ " & FORMAT(Change, "0.0%") & " MoM",
    "▼ " & FORMAT(ABS(Change), "0.0%") & " MoM"
)
```

---

### Accounts Trend Label
```dax
Accounts Trend Label =
VAR Change = [Accounts MoM Change]
RETURN
IF(
    Change >= 0,
    "▲ +" & FORMAT(Change, "0") & " this month",
    "▼ " & FORMAT(Change, "0") & " this month"
)
```

---

### Churn Trend Label
-- NOTE: For churn, going UP is bad. Labels are flipped intentionally.
```dax
Churn Trend Label =
VAR Change = [Churn MoM % Change]
RETURN
IF(
    Change <= 0,
    "▲ " & FORMAT(ABS(Change), "0.0%") & " improvement",
    "▼ Churn up " & FORMAT(Change, "0.0%")
)
```

---

## STEP 3 — Trend Color Measures (used in Format → fx → Field value)

### MRR Trend Color
```dax
MRR Trend Color = IF([MRR MoM % Change] >= 0, "#22C55E", "#EF4444")
```

### ARR Trend Color
```dax
ARR Trend Color = IF([ARR MoM % Change] >= 0, "#22C55E", "#EF4444")
```

### ARPU Trend Color
```dax
ARPU Trend Color = IF([ARPU MoM % Change] >= 0, "#22C55E", "#EF4444")
```

### Accounts Trend Color
```dax
Accounts Trend Color = IF([Accounts MoM Change] >= 0, "#22C55E", "#EF4444")
```

### Churn Trend Color
-- NOTE: Flipped. More churn = red. Less churn = green.
```dax
Churn Trend Color = IF([Churn MoM % Change] <= 0, "#22C55E", "#EF4444")
```

---

## STEP 4 — Add to Card Visuals (do this for each card)

1. Click the KPI card (e.g. Current Active MRR card)
2. In Visualizations pane → drag the matching Trend Label measure into Values
   - MRR card → drag "MRR Trend Label"
   - ARR card → drag "ARR Trend Label"
   - ARPU card → drag "ARPU Trend Label"
   - Accounts card → drag "Accounts Trend Label"
   - Churned Accounts card → drag "Churn Trend Label"
3. In Format pane → Data labels → Font color → click fx button
4. Set format style to "Field value"
5. Select the matching color measure (e.g. "MRR Trend Color") → OK

---

## IMPORTANT — Before you start

Make sure your Calendar table is marked as a date table:
→ Click the Calendar table in Data pane
→ Table tools ribbon → Mark as date table → select the Date column

Without this, DATEADD will not work correctly.

Your confirmed Calendar date column: Calendar[Date]
