# Logs Insights Query Recipes

Logs Insights is more powerful than `filter-log-events` for aggregation and analysis. Always use the two-step pattern:

1. `aws logs start-query` → returns a `queryId`
2. `sleep 3` (as a **separate command**, not chained with `&&`)
3. `aws logs get-query-results --query-id "$QUERY_ID"` → returns results

---

### Error Count by Type
```
fields @timestamp, @message
| filter @message like /ERROR/
| parse @message '"message": "*"' as error_msg
| stats count() by error_msg
| sort count desc
| limit 20
```

### Request Latency Analysis
```
fields @timestamp, @message
| filter @message like /request completed/
| parse @message '"duration": *,' as duration_ms
| stats avg(duration_ms), max(duration_ms), p95(duration_ms), count() by bin(5m)
```

### Errors Over Time
```
fields @timestamp, @message
| filter @message like /ERROR/
| stats count() by bin(5m)
| sort @timestamp asc
```

### Most Active Users (by request volume)
```
fields @timestamp, @message
| parse @message '"user_id": *,' as user_id
| filter user_id != ""
| stats count() by user_id
| sort count desc
| limit 20
```

### Find All Unique Error Messages
```
fields @timestamp, @message
| filter @message like /ERROR/
| parse @message '"message": "*"' as error_msg
| dedup error_msg
| sort @timestamp desc
```

### HTTP Status Code Distribution
```
fields @timestamp, @message
| parse @message '"status": *,' as status_code
| filter status_code like /[0-9]+/
| stats count() by status_code
| sort count desc
```

### Slow Requests (above threshold)
```
fields @timestamp, @message
| parse @message '"duration": *,' as duration_ms
| filter duration_ms > 1000
| sort duration_ms desc
| limit 20
```

### Errors by Service/Logger
```
fields @timestamp, @message
| filter @message like /ERROR/
| parse @message '"logger": "*"' as logger
| stats count() by logger
| sort count desc
```

### Total Error Count
```
fields @timestamp, @message
| filter @message like /ERROR|Exception|FATAL/
| stats count() as error_count
```

### Errors by Endpoint/Path
```
fields @timestamp, @message
| filter @message like /ERROR/
| parse @message '"path": "*"' as endpoint
| stats count() as errors by endpoint
| sort errors desc
| limit 10
```

---

## Notes on Parse Patterns

The `parse` patterns above assume JSON-structured logs. If your application uses a different log format, adjust the parse patterns accordingly. Common alternatives:

- **Python logging**: `parse @message '* - * - * - *' as timestamp, level, logger, message`
- **Nginx access logs**: `parse @message '* - - [*] "* * *" * *' as ip, time, method, path, protocol, status, size`
- **Plain text with level prefix**: `parse @message '[*] *' as level, message`
