# Monitoring Command Templates

AWS CLI commands and Logs Insights queries used by the proactive monitoring commands (`status`, `report`, `alarms`, `diff`). Replace variables with values from `config.json`:
- `$AWS_CLI` → `config.aws_cli`
- `$REGION` → `config.region`
- `$CLUSTER` → cluster name from `config.ecs`

---

## CloudWatch Metrics

### ECS CPU Utilization (last 30 min, 5-min periods)
```bash
$AWS_CLI cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name CPUUtilization \
  --dimensions Name=ClusterName,Value=$CLUSTER \
  --start-time $(date -d '30 minutes ago' -u +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average Maximum \
  --region $REGION --output json
```

### ECS Memory Utilization (last 30 min, 5-min periods)
```bash
$AWS_CLI cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name MemoryUtilization \
  --dimensions Name=ClusterName,Value=$CLUSTER \
  --start-time $(date -d '30 minutes ago' -u +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics Average Maximum \
  --region $REGION --output json
```

### Custom Time Range (for report command)
Replace `30 minutes ago` with the desired time range. Common values:
- `1 hour ago` — last hour
- `24 hours ago` — last day
- `$(date -d 'yesterday' -u +%Y-%m-%dT%H:%M:%S)` — since yesterday

---

## ECS Service Health

### Service Status (running/desired/pending)
```bash
$AWS_CLI ecs describe-services \
  --cluster $CLUSTER \
  --services $SERVICE_ARN \
  --region $REGION --output json \
  --query 'services[].{name:serviceName,desired:desiredCount,running:runningCount,pending:pendingCount,status:status}'
```

### Recently Stopped Tasks
```bash
$AWS_CLI ecs list-tasks \
  --cluster $CLUSTER \
  --desired-status STOPPED \
  --region $REGION --output json
```

### Stopped Task Details (crash reasons)
```bash
$AWS_CLI ecs describe-tasks \
  --cluster $CLUSTER \
  --tasks $TASK_ARN \
  --region $REGION --output json \
  --query 'tasks[].{taskArn:taskArn,stoppedReason:stoppedReason,stopCode:stopCode,stoppedAt:stoppedAt,containers:containers[].{name:name,exitCode:exitCode,reason:reason}}'
```

---

## Alarm Queries

### All Alarms (full details)
```bash
$AWS_CLI cloudwatch describe-alarms \
  --region $REGION --output json \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue,reason:StateReason,metric:MetricName,namespace:Namespace,threshold:Threshold,comparison:ComparisonOperator,period:Period,evaluationPeriods:EvaluationPeriods}'
```

### Only Alarms in ALARM State
```bash
$AWS_CLI cloudwatch describe-alarms \
  --state-value ALARM \
  --region $REGION --output json
```

### Alarm-to-Log-Group Mapping

When presenting alarms, map the alarm's namespace to the relevant log group category:
| Namespace | Log Group Category | Suggested Investigation |
|-----------|-------------------|------------------------|
| `AWS/ApplicationELB` | ecs-app | `/cloudwatch 500 errors` |
| `AWS/ECS` | container-insights | `/cloudwatch ECS task crashes` |
| `AWS/RDS` | rds | `/cloudwatch database errors` |
| `AWS/Lambda` | lambda | `/cloudwatch lambda errors` |
| `AWS/ApiGateway` | api-gateway | `/cloudwatch API errors` |

---

## Monitoring Logs Insights Queries

### Total Error Count (for status/diff)
```
fields @timestamp, @message
| filter @message like /ERROR|Exception|FATAL/
| stats count() as error_count
```

### Error Count by Type (for report/diff)
```
fields @timestamp, @message
| filter @message like /ERROR/
| parse @message '"message": "*"' as error_msg
| stats count() as occurrences by error_msg
| sort occurrences desc
| limit 10
```

### Error Trend Over Time (for report)
```
fields @timestamp, @message
| filter @message like /ERROR/
| stats count() as errors by bin(5m)
| sort @timestamp asc
```

### P95 Latency by Time Bin (for report)
```
fields @timestamp, @message
| filter @message like /request completed|duration/
| parse @message '"duration": *,' as duration_ms
| stats avg(duration_ms) as avg_ms, max(duration_ms) as max_ms, pct(duration_ms, 95) as p95_ms by bin(5m)
| sort @timestamp asc
```

### Errors by Endpoint (for report)
```
fields @timestamp, @message
| filter @message like /ERROR/
| parse @message '"path": "*"' as endpoint
| stats count() as errors by endpoint
| sort errors desc
| limit 10
```

---

## Batching Multiple Log Groups

Use `--log-group-names` (plural) to query multiple log groups in a single Logs Insights query:

```bash
$AWS_CLI logs start-query \
  --log-group-names "$LOG_GROUP_1" "$LOG_GROUP_2" \
  --start-time $(date -d '30 minutes ago' +%s) \
  --end-time $(date +%s) \
  --query-string '...' \
  --region $REGION --output text --query 'queryId'
```

This reduces the number of queries and `sleep` waits needed.
