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

# ========= FUNCTIONS =========

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
    local subnets_csv
    subnets_csv=$(IFS=, ; echo "${subnets[*]}")

    local SEC_GROUPS
    SEC_GROUPS=$(get_service_security_groups)
    local SEC_GROUPS_CSV
    SEC_GROUPS_CSV=$(IFS=, ; echo "${SEC_GROUPS[*]}")

    echo "🔧 Updating ECS service network settings..."
    echo "   → Subnets: $subnets_csv"
    echo "   → Security groups: $SEC_GROUPS_CSV"

    aws ecs update-service \
        --cluster "$CLUSTER_NAME" \
        --service "$SERVICE_NAME" \
        --network-configuration "awsvpcConfiguration={subnets=[$subnets_csv],securityGroups=[$SEC_GROUPS_CSV],assignPublicIp=ENABLED}" \
        --force-new-deployment \
        --region "$REGION" >/dev/null

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
    echo "✅ Verify service health, then rerun with --mode restore to bring it back."

elif [ "$MODE" == "restore" ]; then
    echo "🔄 Restoring ECS service '$SERVICE_NAME' to its original subnet configuration..."
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
