---
name: cloudwatch
description: Debug production issues and monitor AWS infrastructure via CloudWatch. Use when the user reports errors, wants to investigate production behavior, check logs, debug OAuth, API errors, ECS tasks, database issues, WAF blocks, or any production incident. Also use when the user says "check logs", "what's failing", "why is X broken", "system status", "error report", "check alarms", or mentions CloudWatch, log groups, or alarms. Supports proactive commands: status (health check), report (error summary), alarms (alarm states), diff (error rate comparison). Run `/cloudwatch configure` to auto-discover your AWS infrastructure on first use.
allowed-tools: Bash(aws:*), Bash(sleep:*), Bash(mkdir:*), Read, Write, Glob, Grep
---

# CloudWatch Log Debugger

Query, filter, and analyze AWS CloudWatch logs for production debugging. Auto-configures to any AWS environment.

## Current State
- **Current timestamp (epoch seconds):** !`date +%s`
- **Current time (human-readable):** !`date '+%Y-%m-%d %H:%M:%S %Z'`

---

## First-Time Setup

If `config.json` does not exist in this skill's directory, tell the user:

> This skill needs to discover your AWS infrastructure first. Run `/cloudwatch configure` or let me auto-configure now.

Then read and follow the instructions in `scripts/configure.sh` to generate `config.json`.

---

## Configuration

Read `config.json` from this skill's directory for all environment-specific values. The config contains:

- `aws_cli` — path to the AWS CLI binary (e.g., `aws` or `/snap/bin/aws`)
- `region` — AWS region
- `log_groups` — discovered log groups with their purpose and stream prefixes
- `default_log_group` — which log group to query when the user doesn't specify
- `ecs_clusters` — ECS clusters if any
- `alarms` — CloudWatch alarms if any
- `output_dir` — where to save log files (default: `logs/`)

Use these values in all commands instead of hardcoded strings.

---

## Command Dispatch

Parse `$ARGUMENTS` to determine which command to run:

| If `$ARGUMENTS` starts with... | Action |
|---|---|
| `configure` | Run configuration (see First-Time Setup) |
| `status` | Jump to **Status Check** below |
| `report` | Jump to **Report** below (remaining args = time range) |
| `alarms` | Jump to **Alarms** below |
| `diff` | Jump to **Error Rate Comparison** below (remaining args = time windows) |
| anything else | Jump to **Workflow** below (reactive debugging) |

---

## Status Check

Quick health dashboard. No arguments needed.

Read `config.json`, then run these queries:

### 1. Error Count (last 30 min)

Run a Logs Insights query against app log groups (priority <= 2). Use `--log-group-names` to batch:

```bash
QUERY_ID=$($AWS_CLI logs start-query \
  --log-group-names "$LOG_GROUP_1" "$LOG_GROUP_2" \
  --start-time $(date -d '30 minutes ago' +%s) \
  --end-time $(date +%s) \
  --query-string 'fields @timestamp, @message | filter @message like /ERROR|Exception|FATAL/ | stats count() as error_count by @logStream' \
  --region $REGION --output text --query 'queryId')
```

Then `sleep 3`, then `get-query-results`.

### 2. Alarm States (live)

Fetch current alarm states from the API — do NOT use cached values from config:

```bash
$AWS_CLI cloudwatch describe-alarms \
  --region $REGION --output json \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue,metric:MetricName,namespace:Namespace,threshold:Threshold}'
```

### 3. ECS Service Health

For each cluster/service in `config.ecs`:

```bash
$AWS_CLI ecs describe-services \
  --cluster $CLUSTER \
  --services $SERVICE_ARN \
  --region $REGION --output json \
  --query 'services[].{name:serviceName,desired:desiredCount,running:runningCount,pending:pendingCount}'
```

### 4. Recently Stopped Tasks

```bash
$AWS_CLI ecs list-tasks --cluster $CLUSTER --desired-status STOPPED --region $REGION --output json
```

If any stopped tasks exist, describe them for crash reasons:

```bash
$AWS_CLI ecs describe-tasks --cluster $CLUSTER --tasks $TASK_ARNS \
  --region $REGION --output json \
  --query 'tasks[].{taskArn:taskArn,stoppedReason:stoppedReason,stopCode:stopCode,stoppedAt:stoppedAt,containers:containers[].{name:name,exitCode:exitCode,reason:reason}}'
```

### 5. CPU/Memory Utilization

```bash
$AWS_CLI cloudwatch get-metric-statistics \
  --namespace AWS/ECS --metric-name CPUUtilization \
  --dimensions Name=ClusterName,Value=$CLUSTER \
  --start-time $(date -d '30 minutes ago' -u +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 --statistics Average Maximum \
  --region $REGION --output json
```

Same for `MemoryUtilization`.

### Output Format

Present as a dashboard summary:

```
## System Status (as of YYYY-MM-DD HH:MM:SS)

### Errors (last 30 min)
- app-backend: 12 errors
- app-frontend: 0 errors

### Alarms
- OK: my-app-ECS-CPU-High (CPUUtilization < 80)
- **ALARM: my-app-ApplicationErrors-High** (ErrorCount > 50)

### ECS Services
- my-app-web: 2/2 running, 0 pending
- my-app-worker: 1/1 running, 0 pending

### Resource Utilization (30-min avg)
- CPU: 45% avg, 62% max
- Memory: 71% avg, 78% max
```

Save to `$OUTPUT_DIR/YYYYMMDD_HHMMSS_status.txt`.

---

## Report

Periodic summary over a configurable time range. Parse the time range from the remaining arguments after `report` (e.g., `last 24 hours`, `last 6h`, `today`). Default: **last 1 hour**.

Run these Logs Insights queries against app log groups:

### 1. Top Errors

```
fields @timestamp, @message
| filter @message like /ERROR/
| parse @message '"message": "*"' as error_msg
| stats count() as occurrences by error_msg
| sort occurrences desc
| limit 10
```

### 2. Error Trend

```
fields @timestamp, @message
| filter @message like /ERROR/
| stats count() as errors by bin(5m)
| sort @timestamp asc
```

For time ranges > 6 hours, use `bin(30m)` instead of `bin(5m)`.

### 3. P95 Latency

```
fields @timestamp, @message
| filter @message like /request completed|duration/
| parse @message '"duration": *,' as duration_ms
| stats avg(duration_ms) as avg_ms, max(duration_ms) as max_ms, pct(duration_ms, 95) as p95_ms by bin(5m)
| sort @timestamp asc
```

### 4. Most Affected Endpoints

```
fields @timestamp, @message
| filter @message like /ERROR/
| parse @message '"path": "*"' as endpoint
| stats count() as errors by endpoint
| sort errors desc
| limit 10
```

### Output Format

```
## Report: Last 1 Hour (HH:MM - HH:MM)

### Top Errors
| # | Error | Count |
|---|-------|-------|
| 1 | ConnectionRefused: DB pool exhausted | 23 |
| 2 | TokenExpiredError | 8 |

### Error Trend (5-min bins)
HH:00  ██████████ 23
HH:05  ████ 8
HH:10  ██ 4
...

### Latency
- Average: 120ms
- P95: 450ms
- Max: 2300ms

### Most Affected Endpoints
| Endpoint | Errors |
|----------|--------|
| /api/auth/callback | 15 |
| /api/users/profile | 8 |
```

Save to `$OUTPUT_DIR/YYYYMMDD_HHMMSS_report.txt`.

---

## Alarms

List all CloudWatch alarms with their current state.

### 1. Fetch Live Alarm Data

```bash
$AWS_CLI cloudwatch describe-alarms \
  --region $REGION --output json
```

### 2. Present Grouped by State

Group alarms by state. Show **ALARM** state first (highlighted), then OK, then INSUFFICIENT_DATA.

For each alarm, show:
- Alarm name
- Metric and namespace
- Threshold and comparison operator
- Evaluation periods and period length
- State reason (for alarms not in OK state)

### 3. Map to Log Groups

Map alarm namespaces to log group categories for investigation suggestions:
- `AWS/ApplicationELB` → ecs-app → suggest `/cloudwatch 500 errors`
- `AWS/ECS` → container-insights → suggest `/cloudwatch ECS task crashes`
- `AWS/RDS` → rds → suggest `/cloudwatch database errors`
- `AWS/Lambda` → lambda → suggest `/cloudwatch lambda errors`

### Output Format

```
## CloudWatch Alarms

### ALARM (1)
- **my-app-ApplicationErrors-High**
  Metric: AWS/ApplicationELB > ErrorCount
  Condition: ErrorCount > 50 for 1 period(s) of 300s
  Reason: Threshold crossed...
  → Investigate: /cloudwatch 500 errors in the last hour

### OK (2)
- my-app-ECS-CPU-High
  Metric: AWS/ECS > CPUUtilization
  Condition: CPUUtilization > 80 for 2 period(s) of 300s

### INSUFFICIENT_DATA (0)
None.
```

Save to `$OUTPUT_DIR/YYYYMMDD_HHMMSS_alarms.txt`.

---

## Error Rate Comparison

Compare error rates between two time windows to detect regressions or confirm fixes.

### 1. Parse Time Windows

From the remaining arguments after `diff`. Defaults:
- **Window A** (current): last 30 minutes
- **Window B** (baseline): 30–60 minutes ago

Support natural language like:
- `last 1h vs yesterday same time`
- `last 30m vs 2h ago`
- `post-deploy vs pre-deploy` (user should provide timestamps)

### 2. Run Error Count for Both Windows

Use `--log-group-names` to batch app log groups into one query per window:

```
fields @timestamp, @message
| filter @message like /ERROR|Exception|FATAL/
| stats count() as error_count
```

Run this query **twice**: once with Window A timestamps, once with Window B timestamps.

### 3. Run Error-by-Type for Both Windows

```
fields @timestamp, @message
| filter @message like /ERROR/
| parse @message '"message": "*"' as error_msg
| stats count() as cnt by error_msg
| sort cnt desc
| limit 15
```

Run this query **twice** for both windows.

### 4. Compute and Present

Calculate:
- Percentage change: `((A - B) / B) * 100`
- New errors: errors in Window A that don't appear in Window B
- Resolved errors: errors in Window B that don't appear in Window A

### Output Format

```
## Error Rate Comparison

**Window A (current):** HH:MM - HH:MM
**Window B (baseline):** HH:MM - HH:MM

### Summary
| Log Group | Baseline | Current | Change |
|-----------|----------|---------|--------|
| app-backend | 5 | 23 | +360% ↑ |
| app-frontend | 2 | 1 | -50% ↓ |

### New/Changed Errors
| Error | Baseline | Current | Delta |
|-------|----------|---------|-------|
| DB pool exhausted | 0 | 18 | **NEW** |
| TokenExpired | 3 | 2 | -33% |

### Assessment
**REGRESSION** — Error rate increased 360% in app-backend.
Primary cause: "DB pool exhausted" (18 new occurrences).
Recommendation: Check database connection pool settings.
```

Label the assessment as:
- **REGRESSION** — if current errors are significantly higher (>20% increase)
- **IMPROVEMENT** — if current errors are lower (>20% decrease)
- **STABLE** — if change is within ±20%

Save to `$OUTPUT_DIR/YYYYMMDD_HHMMSS_diff.txt`.

---

## Workflow

### Step 1: Understand the Problem

If `$ARGUMENTS` was provided (e.g., the user ran `/cloudwatch 500 errors in the last hour`), use it as the problem description and skip clarification.

Otherwise, determine:
1. **What happened?** — Error message, HTTP status code, user report
2. **When?** — Convert relative times to absolute timestamps using the Current State above
3. **Which log group?** — Match the problem to a log group from `config.json`. If unsure, use `default_log_group`

### Step 2: Query Logs

Always use `--region` from config. Use the `aws_cli` path from config.

#### Quick Search (filter by pattern)
```bash
$AWS_CLI logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern "ERROR" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --region $REGION \
  --output json
```

#### Logs Insights (preferred for analysis)
```bash
QUERY_ID=$($AWS_CLI logs start-query \
  --log-group-name "$LOG_GROUP" \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --query-string 'fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc | limit 50' \
  --region $REGION \
  --output text --query 'queryId')

sleep 3

$AWS_CLI logs get-query-results \
  --query-id "$QUERY_ID" \
  --region $REGION \
  --output json
```

**Important:** Always run `sleep` and `get-query-results` as separate commands, never chained with `&&`. This avoids allowed-tools pattern matching issues.

#### Filter by Log Stream
Use `--log-stream-name-prefix` to narrow down to a specific container or service, based on the stream prefixes in `config.json`.

### Step 3: Save Results to File

**MANDATORY** after every query:

```bash
mkdir -p $OUTPUT_DIR
$AWS_CLI logs filter-log-events ... > "$OUTPUT_DIR/$(date +%Y%m%d_%H%M%S)_description.txt"
```

Naming convention: `YYYYMMDD_HHMMSS_<description>.txt`

After saving, read the file and present a summary. Always tell the user the file path.

### Step 4: Analyze and Diagnose

1. **Identify root cause** — find the actual exception, stack trace, or error message
2. **Check correlation IDs** — if the app uses correlation IDs, trace the request across log entries
3. **Cross-reference with code** — if the error points to a file/function, read that code
4. **Check related log groups** — DB errors → check RDS logs. Blocked requests → check WAF logs

### Step 5: Report to User

Present findings as:
1. **What happened** — the actual error/exception
2. **When** — timestamp(s)
3. **Where** — which service, file, function
4. **Why** — root cause analysis
5. **Fix** — suggested code change or configuration fix
6. **File** — path to the saved log file

---

## Additional Resources

- For common debugging scenarios (auth, 500s, DB, WAF, ECS, network, tracing), read `references/scenarios.md`
- For Logs Insights query recipes (aggregations, latency analysis, error trends), read `references/recipes.md`
- For monitoring command templates (metrics, ECS health, alarms, batching), read `references/monitoring.md`

---

## Important Notes

- **Log retention varies** — check your account settings. For older logs, check S3 archive buckets if configured
- **Structured JSON logs**: If the app outputs JSON, use field-based filtering: `timestamp`, `level`, `message`, `correlation_id`, etc.
- **Time format**: `filter-log-events` expects epoch **milliseconds** for `--start-time`. Logs Insights expects epoch **seconds**
- **Output format**: Always use `--output json` for results. Use `--output text` only for extracting simple values like query IDs
- **Rate limits**: CloudWatch API has rate limits. If throttled, wait a few seconds and retry
- **Never expose secrets** in log output or saved files. Redact tokens, keys, or credentials before showing to the user
