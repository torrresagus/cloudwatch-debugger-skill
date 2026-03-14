# Common Debugging Scenarios

These are ready-to-use query templates. Replace variables with values from `config.json`:
- `$AWS_CLI` → `config.aws_cli`
- `$REGION` → `config.region`
- `$LOG_GROUP` → the appropriate log group from `config.log_groups`

---

### Application Errors (HTTP 500, unhandled exceptions)

Use the **ecs-app** or main backend log group.

```bash
# Quick search for errors
$AWS_CLI logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern "ERROR" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --region $REGION --output json

# Logs Insights for 500s (two-step: start then get)
$AWS_CLI logs start-query \
  --log-group-name "$LOG_GROUP" \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --query-string 'fields @timestamp, @message | filter @message like /500|Internal Server Error|Unexpected error/ | sort @timestamp desc | limit 30' \
  --region $REGION --output text --query 'queryId'
```

### Authentication / OAuth Errors

Use the **ecs-app** or main backend log group.

```bash
$AWS_CLI logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern "\"auth\" OR \"oauth\" OR \"token\" OR \"unauthorized\" OR \"401\" OR \"403\"" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --region $REGION --output json
```

### Database Connection Issues

Query both the **ecs-app** log group (app-side errors) and the **rds** log group (database-side errors).

```bash
# App-side DB errors
$AWS_CLI logs filter-log-events \
  --log-group-name "$APP_LOG_GROUP" \
  --filter-pattern "\"database\" OR \"connection\" OR \"sqlalchemy\" OR \"asyncpg\" OR \"prisma\" OR \"sequelize\" OR \"typeorm\"" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --region $REGION --output json

# Database-side errors (use rds log group)
$AWS_CLI logs filter-log-events \
  --log-group-name "$RDS_LOG_GROUP" \
  --filter-pattern "ERROR" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --region $REGION --output json
```

### Rate Limiting / WAF Blocks

Query the **waf** log group for blocked requests, and the **ecs-app** log group for app-side rate limit hits.

```bash
# WAF blocked requests
$AWS_CLI logs filter-log-events \
  --log-group-name "$WAF_LOG_GROUP" \
  --filter-pattern "\"BLOCK\"" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --region $REGION --output json

# App-side rate limits
$AWS_CLI logs filter-log-events \
  --log-group-name "$APP_LOG_GROUP" \
  --filter-pattern "\"rate limit\" OR \"429\" OR \"throttl\"" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --region $REGION --output json
```

### ECS Task Crashes / OOM

Query the **container-insights** log group, and optionally use ECS API.

```bash
# Container Insights for stopped tasks
$AWS_CLI logs filter-log-events \
  --log-group-name "$CONTAINER_INSIGHTS_LOG_GROUP" \
  --filter-pattern "\"StoppedReason\"" \
  --start-time $(date -d '6 hours ago' +%s000) \
  --region $REGION --output json

# ECS API: list recently stopped tasks
$AWS_CLI ecs list-tasks \
  --cluster $CLUSTER_NAME \
  --desired-status STOPPED \
  --region $REGION

# Describe stopped tasks for crash reason
$AWS_CLI ecs describe-tasks \
  --cluster $CLUSTER_NAME \
  --tasks <task-arn> \
  --region $REGION \
  --query 'tasks[].{stoppedReason:stoppedReason,stopCode:stopCode,containers:containers[].{name:name,exitCode:exitCode,reason:reason}}'
```

### Slow Queries (RDS)

Use the **rds** log group.

```bash
$AWS_CLI logs filter-log-events \
  --log-group-name "$RDS_LOG_GROUP" \
  --filter-pattern "\"duration\"" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --region $REGION --output json
```

### Network Issues (VPC Flow Logs)

Use the **vpc** log group.

```bash
$AWS_CLI logs filter-log-events \
  --log-group-name "$VPC_LOG_GROUP" \
  --filter-pattern "REJECT" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --region $REGION --output json
```

### Lambda Errors

Use the **lambda** log group.

```bash
$AWS_CLI logs filter-log-events \
  --log-group-name "$LAMBDA_LOG_GROUP" \
  --filter-pattern "ERROR" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --region $REGION --output json
```

### Trace a Specific Request (by Correlation ID)

Use the main **ecs-app** log group. Replace `<correlation-id>` with the actual ID.

```bash
$AWS_CLI logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern "\"<correlation-id>\"" \
  --start-time $(date -d '2 hours ago' +%s000) \
  --region $REGION --output json
```

### Trace a Specific User (by email or user ID)

```bash
$AWS_CLI logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern "\"user@example.com\"" \
  --start-time $(date -d '2 hours ago' +%s000) \
  --region $REGION --output json
```
