#!/usr/bin/env bash
#
# CloudWatch Skill — Auto-Configuration
#
# This script discovers your AWS infrastructure and generates config.json.
# Claude should run this script when config.json doesn't exist.
#
# Usage: bash scripts/configure.sh [--region REGION]
#
# What it discovers:
#   - AWS CLI binary location
#   - AWS region (from args, env, or AWS config)
#   - Account ID and identity
#   - All CloudWatch log groups (with size and retention info)
#   - ECS clusters and services
#   - CloudWatch alarms
#
# Output: config.json in the skill's root directory

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SKILL_DIR/config.json"
REGION=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case $1 in
    --region) REGION="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Find AWS CLI ---
find_aws_cli() {
  for candidate in aws /snap/bin/aws /usr/local/bin/aws /usr/bin/aws; do
    if command -v "$candidate" &>/dev/null || [ -x "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  echo "ERROR: AWS CLI not found. Install it: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html" >&2
  exit 1
}

AWS_CLI=$(find_aws_cli)
echo "✓ AWS CLI found: $AWS_CLI"

# --- Detect region ---
if [ -z "$REGION" ]; then
  REGION="${AWS_DEFAULT_REGION:-}"
fi
if [ -z "$REGION" ]; then
  REGION=$($AWS_CLI configure get region 2>/dev/null || echo "")
fi
if [ -z "$REGION" ]; then
  echo "ERROR: Cannot detect AWS region. Pass --region or set AWS_DEFAULT_REGION" >&2
  exit 1
fi
echo "✓ Region: $REGION"

# --- Verify identity ---
echo "Verifying AWS access..."
IDENTITY=$($AWS_CLI sts get-caller-identity --region "$REGION" --output json 2>&1) || {
  echo "ERROR: AWS authentication failed. Check your credentials." >&2
  echo "$IDENTITY" >&2
  exit 1
}
ACCOUNT_ID=$(echo "$IDENTITY" | python3 -c "import sys,json; print(json.load(sys.stdin)['Account'])")
echo "✓ Account: $ACCOUNT_ID"

# --- Discover log groups ---
echo "Discovering CloudWatch log groups..."
LOG_GROUPS_RAW=$($AWS_CLI logs describe-log-groups \
  --region "$REGION" \
  --no-cli-pager \
  --output json \
  --query 'logGroups[].{name:logGroupName,storedBytes:storedBytes,retentionInDays:retentionInDays}' 2>&1) || {
  echo "WARNING: Could not list log groups. Check IAM permissions (logs:DescribeLogGroups)." >&2
  LOG_GROUPS_RAW="[]"
}

# --- Discover ECS clusters ---
echo "Discovering ECS clusters..."
ECS_CLUSTERS_RAW=$($AWS_CLI ecs list-clusters \
  --region "$REGION" \
  --no-cli-pager \
  --output json \
  --query 'clusterArns' 2>&1) || {
  echo "WARNING: Could not list ECS clusters. Check IAM permissions or ECS may not be in use." >&2
  ECS_CLUSTERS_RAW="[]"
}

# For each cluster, get services
ECS_SERVICES="[]"
if [ "$ECS_CLUSTERS_RAW" != "[]" ]; then
  CLUSTER_ARNS=$(echo "$ECS_CLUSTERS_RAW" | python3 -c "import sys,json; [print(c) for c in json.load(sys.stdin)]" 2>/dev/null || echo "")
  if [ -n "$CLUSTER_ARNS" ]; then
    ECS_SERVICES="["
    first=true
    while IFS= read -r cluster_arn; do
      [ -z "$cluster_arn" ] && continue
      cluster_name=$(echo "$cluster_arn" | rev | cut -d'/' -f1 | rev)
      services=$($AWS_CLI ecs list-services \
        --cluster "$cluster_name" \
        --region "$REGION" \
        --output json \
        --query 'serviceArns' 2>/dev/null || echo "[]")
      if [ "$first" = true ]; then first=false; else ECS_SERVICES+=","; fi
      ECS_SERVICES+="{\"cluster\":\"$cluster_name\",\"services\":$services}"
    done <<< "$CLUSTER_ARNS"
    ECS_SERVICES+="]"
  fi
fi

# --- Discover alarms ---
echo "Discovering CloudWatch alarms..."
ALARMS_RAW=$($AWS_CLI cloudwatch describe-alarms \
  --region "$REGION" \
  --no-cli-pager \
  --output json \
  --query 'MetricAlarms[].{name:AlarmName,metric:MetricName,namespace:Namespace,threshold:Threshold,state:StateValue}' 2>&1) || {
  echo "WARNING: Could not list alarms. Check IAM permissions (cloudwatch:DescribeAlarms)." >&2
  ALARMS_RAW="[]"
}

# --- Generate config.json ---
echo "Generating config.json..."

export SKILL_DIR REGION AWS_CLI ACCOUNT_ID LOG_GROUPS_RAW ECS_SERVICES ALARMS_RAW

python3 << 'PYEOF'
import json
import sys
import os

skill_dir = os.environ.get('SKILL_DIR', '.')
region = os.environ.get('REGION', 'us-east-1')
aws_cli = os.environ.get('AWS_CLI', 'aws')
account_id = os.environ.get('ACCOUNT_ID', '')

# Parse discovered data
log_groups_raw = json.loads(os.environ.get('LOG_GROUPS_RAW', '[]'))
ecs_services = json.loads(os.environ.get('ECS_SERVICES', '[]'))
alarms_raw = json.loads(os.environ.get('ALARMS_RAW', '[]'))

# Classify log groups by common patterns
def classify_log_group(name):
    patterns = {
        'ecs-app': {'keywords': ['/ecs/'], 'not': ['frontend', 'containerinsights'], 'purpose': 'Backend application logs', 'priority': 1},
        'ecs-frontend': {'keywords': ['frontend'], 'purpose': 'Frontend application logs', 'priority': 2},
        'container-insights': {'keywords': ['containerinsights'], 'purpose': 'ECS Container Insights (CPU, memory, task crashes)', 'priority': 5},
        'rds': {'keywords': ['/aws/rds/', 'postgresql', 'mysql', 'aurora'], 'purpose': 'Database logs', 'priority': 3},
        'waf': {'keywords': ['waf'], 'purpose': 'WAF request logs (blocked requests, rate limiting)', 'priority': 4},
        'vpc': {'keywords': ['/aws/vpc/'], 'purpose': 'VPC flow logs (network issues)', 'priority': 6},
        'lambda': {'keywords': ['/aws/lambda/'], 'purpose': 'Lambda function logs', 'priority': 5},
        'api-gateway': {'keywords': ['/aws/apigateway/', 'api-gw'], 'purpose': 'API Gateway logs', 'priority': 3},
        'rds-os-metrics': {'keywords': ['RDSOSMetrics'], 'purpose': 'RDS Enhanced Monitoring (OS-level)', 'priority': 7},
    }

    name_lower = name.lower()
    for category, info in patterns.items():
        if any(kw.lower() in name_lower for kw in info['keywords']):
            if 'not' in info and any(exc.lower() in name_lower for exc in info['not']):
                continue
            return category, info['purpose'], info['priority']
    return 'other', 'Other logs', 10

# Build log groups config
log_groups = []
for lg in log_groups_raw:
    category, purpose, priority = classify_log_group(lg['name'])
    log_groups.append({
        'name': lg['name'],
        'category': category,
        'purpose': purpose,
        'priority': priority,
        'retention_days': lg.get('retentionInDays'),
        'stored_bytes': lg.get('storedBytes', 0),
    })

# Sort by priority (most important first)
log_groups.sort(key=lambda x: x['priority'])

# Pick default log group (first ecs-app, or first by priority)
default_lg = None
for lg in log_groups:
    if lg['category'] == 'ecs-app':
        default_lg = lg['name']
        break
if not default_lg and log_groups:
    default_lg = log_groups[0]['name']

# Build config
config = {
    '_comment': 'Auto-generated by /cloudwatch configure. Edit as needed.',
    'aws_cli': aws_cli,
    'region': region,
    'account_id': account_id,
    'output_dir': 'logs/',
    'default_log_group': default_lg,
    'log_groups': log_groups,
    'ecs': ecs_services,
    'alarms': [a for a in alarms_raw] if alarms_raw else [],
}

config_path = os.path.join(skill_dir, 'config.json')
with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)

print(f"\n✓ Config written to {config_path}")
print(f"\n=== Summary ===")
print(f"Region:          {region}")
print(f"Account:         {account_id}")
print(f"Log groups:      {len(log_groups)}")
print(f"ECS clusters:    {len(ecs_services)}")
print(f"Alarms:          {len(alarms_raw) if alarms_raw else 0}")
print(f"Default log group: {default_lg}")
print(f"\nLog groups discovered:")
for lg in log_groups:
    ret = f" ({lg['retention_days']}d retention)" if lg.get('retention_days') else " (no retention set)"
    print(f"  [{lg['category']}] {lg['name']}{ret}")

PYEOF

echo ""
echo "✓ Configuration complete! You can now use /cloudwatch to debug issues."
echo "  Edit config.json to customize log group purposes or set a different default."
