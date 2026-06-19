# Data

The raw CSV files aren't included in this repo — they're too large to commit and the original dataset is publicly available.

## Download

Get the RavenStack dataset directly from the source:  
**https://rivalytics.medium.com**

Credit: River @ Rivalytics — used for portfolio purposes under MIT-like licence.

## Files needed

Download these and drop them into this folder before running the SQL script:

| File | Rows | Size (approx) |
|---|---|---|
| ravenstack_accounts.csv | 500 | ~50KB |
| ravenstack_subscriptions.csv | 5,000 | ~450KB |
| ravenstack_feature_usage.csv | 24,979 | ~1.4MB |
| ravenstack_support_tickets.csv | 2,000 | ~150KB |
| ravenstack_churn_events.csv | 600 | ~45KB |

## Load order

Load accounts first — everything else has a foreign key pointing back to it.

```
accounts → subscriptions → feature_usage
accounts → support_tickets
accounts → churn_events
```

Update the COPY paths in `ravenstack_analysis.sql` to point to this folder before running.
