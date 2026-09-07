# Split alternative — six cards

The six-card version, kept for reference. Superseded by
`metabase/01_reporting_feed.sql`, which is one card carrying every level so the
Gsheet extension needs a single connection.

Use these only if you later want a card per report tab — e.g. if the feed query
gets slow enough that you'd rather refresh Sephora and DTC independently, or if
different people should have access to different levels. The feed's
`report_level` column maps 1:1 onto these files:

| report_level | file |
|---|---|
| `Sephora Segment` | `01_sephora_by_segment_weekly.sql` |
| `DTC Channel` | `02_dtc_by_channel_weekly.sql` |
| `Business` | `03_performance_monthly.sql` |
| `Campaign` | `04_campaign_detail_weekly.sql` |
| `Site` | `05_site_and_customer_weekly.sql` |
| `Health` | `06_data_health.sql` |
