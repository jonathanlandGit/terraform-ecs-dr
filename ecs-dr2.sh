cat <<'EOF' > ecs-dr.sh
#!/bin/bash
set -euo pipefail

# ========= CONFIG =========
CLUSTER_NAME=""
SERVICE_NAME=""
REGION="us-east-1"
AZ_TO_FAIL="us-east-1a"
CHECK_INTERVAL=10
ORIGINAL_SUBNETS_FIsLE="/tmp/ecs_original_subnets.txt"

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

update_service_subnets() {
    local subnets=("$@")
    local subnets_csv
    subnets_csv=$(IFS=, ; echo "${subnets[*]}")
    echo "Updating service subnets to: $subnets_csv"
    aws ecs update-service \
        --cluster "$CLUSTER_NAME" \
        --service "$SERVICE_NAME" \
        --network-configuration "awsvpcConfiguration={subnets=[$subnets_csv],assignPublicIp=ENABLED}" \
        --force-new-deployment \
        --region "$REGION" >/dev/null
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
    [ ${#tasks[@]} -eq 0 ] && { echo "No tasks to stop."; return; }

    for task in "${tasks[@]}"; do
        echo "Stopping task $task in failed AZ..."
        aws ecs stop-task \
            --cluster "$CLUSTER_NAME" \
            --task "$task" \
            --reason "Simulated AZ failure" \
            --region "$REGION" >/dev/null
    done
}

wait_for_full_redeployment() {
    local target_subnets=("$@")
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
            echo "✅ All $RUNNING_COUNT tasks are running in the expected subnets."
            break
        fi

        echo "Waiting for tasks to reach desired count ($DESIRED_COUNT) in target subnets..."
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
    [ -z "$task_arns" ] && { echo "No running tasks."; return; }

    echo "Current ECS task AZ distribution:"
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
        echo "  - $task => $task_az"
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
    echo "Running ECS failover simulation for cluster '$CLUSTER_NAME' and service '$SERVICE_NAME'..."

    SERVICE_SUBNETS=($(get_service_subnets))
    echo "${SERVICE_SUBNETS[*]}" > "$ORIGINAL_SUBNETS_FILE"
    echo "Saved original subnets: ${SERVICE_SUBNETS[*]}"

    FAILED_SUBNETS=($(get_subnets_in_az "$AZ_TO_FAIL"))
    UPDATED_SUBNETS=()
    for subnet in "${SERVICE_SUBNETS[@]}"; do
        [[ ! " ${FAILED_SUBNETS[*]} " =~ " ${subnet} " ]] && UPDATED_SUBNETS+=("$subnet")
    done

    update_service_subnets "${UPDATED_SUBNETS[@]}"

    TASKS_TO_STOP=($(get_tasks_in_az "$AZ_TO_FAIL"))
    [ ${#TASKS_TO_STOP[@]} -ne 0 ] && stop_tasks_in_az "${TASKS_TO_STOP[@]}"

    wait_for_full_redeployment "${UPDATED_SUBNETS[@]}"
    echo "✅ Failover complete. All tasks should now be in the healthy AZs."
    print_task_distribution
    echo "You can verify everything and then run this again with --mode restore when ready."

elif [ "$MODE" == "restore" ]; then
    echo "Restoring ECS service to original subnet configuration for service '$SERVICE_NAME'..."

    [ ! -f "$ORIGINAL_SUBNETS_FILE" ] && { echo "Missing saved subnet file."; exit 1; }
    ORIGINAL_SUBNETS=($(cat "$ORIGINAL_SUBNETS_FILE"))

    update_service_subnets "${ORIGINAL_SUBNETS[@]}"

    echo "Watching until all tasks come back in original subnets..."
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
            echo "✅ All $RUNNING_COUNT tasks are back in the original subnets."
            break
        fi

        echo "Waiting for $DESIRED_COUNT tasks to fully restore..."
        sleep "$CHECK_INTERVAL"
    done

    echo "✅ Restore complete. ECS service back to original configuration."
else
    echo "Unknown mode: $MODE"
    exit 1
fi
EOF
chmod +x ecs-dr.sh
