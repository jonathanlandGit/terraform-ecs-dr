# Overview
Terraform project to test mutli-az ECS diaster recovery exercise

# Run failover simulation
    ./ecs-dr.sh --failover

# After verifying, restore
    ./ecs-dr.sh --restore

# Run failover simulation (examples of flags to pass in)
    ./ecs-dr.sh --mode failover --cluster dr-test-cluster --service dr-test-service-1
    ./ecs-dr.sh --mode failover --cluster dr-test-cluster --service dr-test-service-2
    ./ecs-dr.sh --mode failover --cluster dr-test-cluster --service dr-test-service-3
    ./ecs-dr.sh --mode failover --cluster dr-test-cluster --service dr-test-service-4


# After verifying, restores
./ecs-dr.sh --mode restore --cluster dr-test-cluster --service dr-test-service-1
./ecs-dr.sh --mode restore --cluster dr-test-cluster --service dr-test-service-2
./ecs-dr.sh --mode restore --cluster dr-test-cluster --service dr-test-service-3
./ecs-dr.sh --mode restore --cluster dr-test-cluster --service dr-test-service-4


