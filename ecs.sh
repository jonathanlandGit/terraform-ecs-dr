#!/bin/bash
set -euo pipefail

# ---------- CONFIG ----------
CLUSTER_NAME="dr-test-cluster"
SERVICE_NAME="dr-test-service"
AZ_TO_FAIL="us-east-1a"        # AZ to simulate failure
REGION="us-east-1"
CHECK_INTERVAL=10              # seconds
RESTORE_DELAY=300              # seconds (5 min before restoring subnets)

# ---------- FUNCTIONS ----------
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
    echo "Updating ECS service subnets to: $subnets_csv"
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

    if [ -z "$task_arns" ]; then
        echo ""
        return 0
    fi

    for task in $task_arns; do
        eni=$(aws ecs describe-tasks \
            --cluster "$CLUSTER_NAME" \
            --tasks "$task" \
            --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
            --output text \
            --region "$REGION" || echo "")

        if [ -z "$eni" ]; then
            continue
        fi

        task_az=$(aws ec2 describe-network-interfaces \
            --network-interface-ids "$eni" \
            --query "NetworkInterfaces[0].AvailabilityZone" \
            --output text \
            --region "$REGION" || echo "")

        if [[ "$task_az" == "$az" ]]; then
            tasks_in_az+=("$task")
        fi
    done

    echo "${tasks_in_az[@]:-}"
}

stop_tasks_in_az() {
    local tasks=("$@")
    if [ ${#tasks[@]} -eq 0 ]; then
        echo "No tasks to stop."
        return
    fi

    for task in "${tasks[@]}"; do
        echo "Stopping task $task in failed AZ..."
        aws ecs stop-task \
            --cluster "$CLUSTER_NAME" \
            --task "$task" \
            --reason "Simulated AZ failure" \
            --region "$REGION" >/dev/null
    done
}

wait_for_deployment() {
    local target_subnets=("$@")
    local all_running
    echo "Waiting for ECS tasks to redeploy in new subnets..."
    while true; do
        all_running=true
        task_arns=$(aws ecs list-tasks \
            --cluster "$CLUSTER_NAME" \
            --service-name "$SERVICE_NAME" \
            --desired-status RUNNING \
            --query "taskArns[]" \
            --output text \
            --region "$REGION" || echo "")

        if [ -z "$task_arns" ]; then
            all_running=false
        else
            for task in $task_arns; do
                eni=$(aws ecs describe-tasks \
                    --cluster "$CLUSTER_NAME" \
                    --tasks "$task" \
                    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
                    --output text \
                    --region "$REGION" || echo "")
                task_subnet=$(aws ec2 describe-network-interfaces \
                    --network-interface-ids "$eni" \
                    --query "NetworkInterfaces[0].SubnetId" \
                    --output text \
                    --region "$REGION" || echo "")

                if [[ ! " ${target_subnets[*]} " =~ " ${task_subnet} " ]]; then
                    all_running=false
                fi
            done
        fi

        if [ "$all_running" = true ]; then
            echo "✅ All ECS tasks are running in the expected subnets."
            break
        fi

        echo "Tasks not yet fully redeployed in new subnets. Sleeping $CHECK_INTERVAL seconds..."
        sleep "$CHECK_INTERVAL"
    done
}

monitor_failover() {
    echo "Monitoring ECS task distribution..."
    while true; do
        task_arns=$(aws ecs list-tasks \
            --cluster "$CLUSTER_NAME" \
            --service-name "$SERVICE_NAME" \
            --desired-status RUNNING \
            --query "taskArns[]" \
            --output text \
            --region "$REGION" || echo "")

        if [ -z "$task_arns" ]; then
            echo "No running tasks yet..."
        else
            echo "Current task AZ distribution:"
            for task in $task_arns; do
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
        fi
        sleep "$CHECK_INTERVAL"
    done
}

# ---------- MAIN ----------
echo "Simulating AZ failure for $AZ_TO_FAIL in ECS service $SERVICE_NAME..."

# 1. Capture original service subnets
SERVICE_SUBNETS=($(get_service_subnets))
echo "Service subnets: ${SERVICE_SUBNETS[*]}"

# 2. Identify subnets in the failed AZ
FAILED_SUBNETS=($(get_subnets_in_az "$AZ_TO_FAIL"))
echo "Subnets in failed AZ: ${FAILED_SUBNETS[*]}"

# 3. Remove failed AZ subnets from service
UPDATED_SUBNETS=()
for subnet in "${SERVICE_SUBNETS[@]}"; do
    if [[ ! " ${FAILED_SUBNETS[*]} " =~ " ${subnet} " ]]; then
        UPDATED_SUBNETS+=("$subnet")
    fi
done

# 4. Update ECS service to remove failed AZ subnets
update_service_subnets "${UPDATED_SUBNETS[@]}"

# 5. Stop tasks in failed AZ
TASKS_TO_STOP=($(get_tasks_in_az "$AZ_TO_FAIL"))
if [ ${#TASKS_TO_STOP[@]} -eq 0 ]; then
    echo "No tasks found in $AZ_TO_FAIL to stop."
else
    stop_tasks_in_az "${TASKS_TO_STOP[@]}"
fi

# 6. Wait until all tasks are running in updated subnets
wait_for_deployment "${UPDATED_SUBNETS[@]}"

# 7. Start monitoring in background
monitor_failover &
MONITOR_PID=$!

# ---------- AUTO RESTORE ----------
echo "Waiting $RESTORE_DELAY seconds before restoring original subnets..."
sleep "$RESTORE_DELAY"

echo "Restoring original subnets: ${SERVICE_SUBNETS[*]}"
update_service_subnets "${SERVICE_SUBNETS[@]}"

# Wait until all tasks are running in restored subnets
wait_for_deployment "${SERVICE_SUBNETS[@]}"

# Stop monitoring
kill "$MONITOR_PID" >/dev/null 2>&1 || true
echo "✅ ECS DR simulation complete and service restored."
