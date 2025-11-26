cat <<'EOF' > ecs-dr.sh
#!/bin/bash
set -euo pipefail

# ========= CONFIG VARS =========
CLUSTER_NAME=""
SERVICE_NAME=""
REGION="us-east-1"
AZ_TO_FAIL="us-east-1b"
CHECK_INTERVAL=10
ORIGINAL_SUBNETS_FILE="/tmp/ecs_original_subnets.txt"
SNS_TOPIC_ARN="<UPDATE_HERE>"  # Replace with your SNS topic ARN

# ========= FUNCTIONS =========

send_sns_alert() {
    local subject="$1"
    local message="$2"

    echo "📧 Sending SNS alert: $subject"
    aws sns publish \
        --topic-arn "$SNS_TOPIC_ARN" \
        --subject "$subject" \
        --message "$message" \
        --region "$REGION"
}

get_subnets_in_az() {
    local az=$1
    aws ec2 describe-subnets \
        --filters "Name=availability-zone,Values=$az" \
        --query "Subnets[].SubnetId" \
        --output text \
        --region "$REGION"
}

get_service_subnets() {
    aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --query "services[0].networkConfiguration.awsvpcConfiguration.subnets" \
        --output text \
        --region "$REGION"
}

get_service_security_groups() {
    aws ecs describe-services \
        --cluster "$CLUSTER_NAME" \
        --services "$SERVICE_NAME" \
        --query "services[0].networkConfiguration.awsvpcConfiguration.securityGroups" \
        --output text \
        --region "$REGION"
}

update_service_subnets() {
    local subnets=("$@")
    local subnets_json
    if [ ${#subnets[@]} -eq 0 ]; then
        subnets_json=""
    else
        subnets_json=$(printf '"%s",' "${subnets[@]}" | sed 's/,$//')
    fi

    local SEC_GROUPS_RAW
    SEC_GROUPS_RAW=$(get_service_security_groups)
    if [ -z "$SEC_GROUPS_RAW" ]; then
        echo "❌ No security groups found for the service. ECS update cannot proceed."
        exit 1
    fi

    read -r -a SEC_GROUPS <<<"$SEC_GROUPS_RAW"
    local sec_groups_json
    sec_groups_json=$(printf '"%s",' "${SEC_GROUPS[@]}" | sed 's/,$//')

    echo "🔧 Updating ECS service network settings..."
    echo "   → Subnets: ${subnets[*]}"
    echo "   → Security groups: ${SEC_GROUPS[*]}"

    local json_payload
    json_payload=$(cat <<JSON
{
  "cluster": "${CLUSTER_NAME}",
  "service": "${SERVICE_NAME}",
  "networkConfiguration": {
    "awsvpcConfiguration": {
      "subnets": [${subnets_json}],
      "securityGroups": [${sec_groups_json}],
      "assignPublicIp": "ENABLED"
    }
  },
  "forceNewDeployment": true
}
JSON
)

    aws ecs update-service --cli-input-json "$json_payload" --region "$REGION" >/dev/null
    echo "✅ Service update pushed — ECS will handle redeploying tasks."
}

get_tasks_in_az() {
    local az=$1
    local task_arns tasks_in_az=() eni task_az

    task_arns=$(aws ecs list-tasks \
        --cluster "$CLUSTER_NAME" \
        --service-name "$SERVICE_NAME" \
        --desired-status RUNNING \
        --query "taskArns[]" \
        --output text \
        --region "$REGION" || echo "")

    [ -z "$task_arns" ] && { echo ""; return; }

    for task in $task_arns; do
        eni=$(aws ecs describe-tasks \
            --cluster "$CLUSTER_NAME" \
            --tasks "$task" \
            --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
            --output text \
            --region "$REGION" || echo "")
        [ -z "$eni" ] && continue

        task_az=$(aws ec2 describe-network-interfaces \
            --network-interface-ids "$eni" \
            --query "NetworkInterfaces[0].AvailabilityZone" \
            --output text \
            --region "$REGION" || echo "")
        [[ "$task_az" == "$az" ]] && tasks_in_az+=("$task")
    done

    echo "${tasks_in_az[@]:-}"
}

stop_tasks_in_az() {
    local tasks=("$@")
    [ ${#tasks[@]} -eq 0 ] && { echo "ℹ️  No tasks found in the failed AZ to stop."; return; }

    for task in "${tasks[@]}"; do
        echo "🛑 Stopping task $task (simulating AZ failure: $AZ_TO_FAIL)..."
        aws ecs stop-task \
            --cluster "$CLUSTER_NAME" \
            --task "$task" \
            --reason "Simulated AZ failure ($AZ_TO_FAIL)" \
            --region "$REGION" >/dev/null
    done
}

wait_for_full_redeployment() {
    local target_subnets=("$@")
    echo "⏳ Waiting for ECS to spin up all tasks in the healthy subnets: ${target_subnets[*]}"

    while true; do
        DESIRED_COUNT=$(aws ecs describe-services \
            --cluster "$CLUSTER_NAME" \
            --services "$SERVICE_NAME" \
            --query "services[0].desiredCount" \
            --output text \
            --region "$REGION")

        task_arns=$(aws ecs list-tasks \
            --cluster "$CLUSTER_NAME" \
            --service-name "$SERVICE_NAME" \
            --desired-status RUNNING \
            --query "taskArns[]" \
            --output text \
            --region "$REGION" || echo "")

        RUNNING_COUNT=$(echo "$task_arns" | wc -w)
        all_in_subnets=true

        for task in $task_arns; do
            eni=$(aws ecs describe-tasks \
                --cluster "$CLUSTER_NAME" \
                --tasks "$task" \
                --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
                --output text \
                --region "$REGION" || echo "")
            [ -z "$eni" ] && { all_in_subnets=false; continue; }

            subnet=$(aws ec2 describe-network-interfaces \
                --network-interface-ids "$eni" \
                --query "NetworkInterfaces[0].SubnetId" \
                --output text \
                --region "$REGION" || echo "")
            [[ ! " ${target_subnets[*]} " =~ " ${subnet} " ]] && all_in_subnets=false
        done

        if [[ "$RUNNING_COUNT" -eq "$DESIRED_COUNT" && "$all_in_subnets" == true ]]; then
            echo "✅ All $RUNNING_COUNT tasks are now healthy and running where expected."
            break
        fi

        echo "⌛ Still waiting... ($RUNNING_COUNT/$DESIRED_COUNT tasks healthy)"
        sleep "$CHECK_INTERVAL"
    done
}

print_task_distribution() {
    local task_arns
    task_arns=$(aws ecs list-tasks \
        --cluster "$CLUSTER_NAME" \
        --service-name "$SERVICE_NAME" \
        --desired-status RUNNING \
        --query "taskArns[]" \
        --output text \
        --region "$REGION" || echo "")
    [ -z "$task_arns" ] && { echo "ℹ️  No running tasks detected."; return; }

    echo "📊 Current ECS task placement by AZ:"
    for task in $task_arns; do
        local eni task_az
        eni=$(aws ecs describe-tasks \
            --cluster "$CLUSTER_NAME" \
            --tasks "$task" \
            --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
            --output text \
            --region "$REGION" || echo "")
        task_az=$(aws ec2 describe-network-interfaces \
            --network-interface-ids "$eni" \
            --query "NetworkInterfaces[0].AvailabilityZone" \
            --output text \
            --region "$REGION" || echo "")
        echo "  - $task → $task_az"
    done
}

# ========= MAIN =========

while [[ $# -gt 0 ]]; do
    case $1 in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --cluster)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        --service)
            SERVICE_NAME="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ -z "${MODE:-}" ] || [ -z "${CLUSTER_NAME:-}" ] || [ -z "${SERVICE_NAME:-}" ]; then
    echo "Usage: $0 --mode <failover|restore> --cluster <name> --service <name>"
    exit 1
fi

if [ "$MODE" == "failover" ]; then
    echo "🚨 Starting failover test for ECS service '$SERVICE_NAME' in cluster '$CLUSTER_NAME'..."
    send_sns_alert "ECS Failover Initiated" "Failover for ECS service $SERVICE_NAME in cluster $CLUSTER_NAME is starting. AZ to fail: $AZ_TO_FAIL"

    SERVICE_SUBNETS=($(get_service_subnets))
    echo "${SERVICE_SUBNETS[*]}" > "$ORIGINAL_SUBNETS_FILE"
    echo "💾 Saved original subnets: ${SERVICE_SUBNETS[*]}"

    FAILED_SUBNETS=($(get_subnets_in_az "$AZ_TO_FAIL"))
    UPDATED_SUBNETS=()
    for subnet in "${SERVICE_SUBNETS[@]}"; do
        [[ ! " ${FAILED_SUBNETS[*]} " =~ " ${subnet} " ]] && UPDATED_SUBNETS+=("$subnet")
    done

    echo "🚫 Removing subnets in failed AZ ($AZ_TO_FAIL)..."
    echo "✅ Remaining target subnets: ${UPDATED_SUBNETS[*]}"
    update_service_subnets "${UPDATED_SUBNETS[@]}"

    echo "🧹 Stopping any tasks still running in $AZ_TO_FAIL..."
    TASKS_TO_STOP=($(get_tasks_in_az "$AZ_TO_FAIL"))
    [ ${#TASKS_TO_STOP[@]} -ne 0 ] && stop_tasks_in_az "${TASKS_TO_STOP[@]}"

    wait_for_full_redeployment "${UPDATED_SUBNETS[@]}"
    echo "🎯 Failover complete — all tasks should now be running in the healthy AZs."
    print_task_distribution
    send_sns_alert "ECS Failover Complete" "Failover for ECS service $SERVICE_NAME in cluster $CLUSTER_NAME has completed. All tasks are now running in healthy subnets."
    echo "✅ Verify service health, then rerun with --mode restore to bring it back."

elif [ "$MODE" == "restore" ]; then
    echo "🔄 Restoring ECS service '$SERVICE_NAME' to its original subnet configuration..."
    send_sns_alert "ECS Restore Initiated" "Restoring ECS service $SERVICE_NAME in cluster $CLUSTER_NAME to original subnets."

    [ ! -f "$ORIGINAL_SUBNETS_FILE" ] && { echo "❌ No saved subnet data found — run a failover first."; exit 1; }
    ORIGINAL_SUBNETS=($(cat "$ORIGINAL_SUBNETS_FILE"))
    update_service_subnets "${ORIGINAL_SUBNETS[@]}"

    echo "🕐 Waiting for ECS to redeploy tasks back in the original subnets..."
    while true; do
        print_task_distribution

        DESIRED_COUNT=$(aws ecs describe-services \
            --cluster "$CLUSTER_NAME" \
            --services "$SERVICE_NAME" \
            --query "services[0].desiredCount" \
            --output text \
            --region "$REGION")

        task_arns=$(aws ecs list-tasks \
            --cluster "$CLUSTER_NAME" \
            --service-name "$SERVICE_NAME" \
            --desired-status RUNNING \
            --query "taskArns[]" \
            --output text \
            --region "$REGION" || echo "")

        RUNNING_COUNT=$(echo "$task_arns" | wc -w)
        all_in_subnets=true

        for task in $task_arns; do
            eni=$(aws ecs describe-tasks \
                --cluster "$CLUSTER_NAME" \
                --tasks "$task" \
                --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
                --output text \
                --region "$REGION" || echo "")
            [ -z "$eni" ] && { all_in_subnets=false; continue; }

            subnet=$(aws ec2 describe-network-interfaces \
                --network-interface-ids "$eni" \
                --query "NetworkInterfaces[0].SubnetId" \
                --output text \
                --region "$REGION" || echo "")
            [[ ! " ${ORIGINAL_SUBNETS[*]} " =~ " ${subnet} " ]] && all_in_subnets=false
        done

        if [[ "$RUNNING_COUNT" -eq "$DESIRED_COUNT" && "$all_in_subnets" == true ]]; then
            echo "✅ Restore complete — all $RUNNING_COUNT tasks are back in their original subnets."
            send_sns_alert "ECS Restore Complete" "Restore for ECS service $SERVICE_NAME in cluster $CLUSTER_NAME has completed. All tasks are back in original subnets."
            break
        fi

        echo "⌛ Still waiting for ECS to finish the restore deployment..."
        sleep "$CHECK_INTERVAL"
    done

    echo "🎉 ECS service successfully restored to original configuration."
else
    echo "❌ Unknown mode: $MODE"
    exit 1
fi
EOF

chmod +x ecs-dr.sh
echo "✅ Script ecs-dr.sh created successfully with SNS alerts enabled."
