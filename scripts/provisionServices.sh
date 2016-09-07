#!/bin/bash -e

readonly SERVICE_CONFIG="$DATA_DIR/config.json"

load_services() {
  # TODO: load service configuration from `config.json`
  local service_count=$(cat $SERVICE_CONFIG | jq '.services | length')
  if [[ $service_count -lt 3 ]]; then
    __process_msg "Shippable requires at least api, www and sync to boot"
    exit 1
  else
    __process_msg "Service count : $service_count"
  fi
}

__map_env_vars() {
  if [ "$1" == "SHIPPABLE_API_TOKEN" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.serviceUserToken')
  elif [ "$1" == "SHIPPABLE_VORTEX_URL" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.apiVortexUrl')
  elif [ "$1" == "SHIPPABLE_API_URL" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.apiUrl')
  elif [ "$1" == "SHIPPABLE_WWW_PORT" ]; then
    env_value=50001
  elif [ "$1" == "SHIPPABLE_WWW_URL" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.wwwUrl')
  elif [ "$1" == "SHIPPABLE_FE_URL" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.wwwUrl')
  elif [ "$1" == "LOG_LEVEL" ]; then
    env_value=info
  elif [ "$1" == "SHIPPABLE_RDS_URL" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.redisUrl')
  elif [ "$1" == "SHIPPABLE_ROOT_AMQP_URL" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.amqpUrlRoot')
  elif [ "$1" == "SHIPPABLE_AMQP_DEFAULT_EXCHANGE" ]; then
    env_value=$(cat $STATE_FILE | jq -r '.systemSettings.amqpDefaultExchange')
  elif [ "$1" == "RUN_MODE" ]; then
    env_value=production
  # TODO: Populate this
  elif [ "$1" == "DOCKER_VERSION" ]; then
    env_value=1.12.1
  elif [ "$1" == "DEFAULT_CRON_LOOP_HOURS" ]; then
    env_value=2
  elif [ "$1" == "API_RETRY_INTERVAL" ]; then
    env_value=3
  elif [ "$1" == "PROVIDERS" ]; then
    env_value=ec2
  elif [ "$1" == "SHIPPABLE_AWS_ACCOUNT_ID" ]; then
    env_value=null
  elif [ "$1" == "REGISTRY_ACCOUNT_ID" ]; then
    env_value=null
  elif [ "$1" == "REGISTRY_REGION" ]; then
    env_value=null
  # TODO: Populate this
  elif [ "$1" == "GITHUB_LINK_SYSINT_ID" ]; then
    env_value=null
  # TODO: Populate this
  elif [ "$1" == "BITBUCKET_LINK_SYSINT_ID" ]; then
    env_value=null
  elif [ "$1" == "BITBUCKET_CLIENT_ID" ]; then
    env_value=null
  elif [ "$1" == "BITBUCKET_CLIENT_SECRET" ]; then
    env_value=null
  elif [ "$1" == "COMPONENT" ]; then
    env_value=$2
  elif [ "$1" == "JOB_TYPE" ]; then
    env_value=$3
  else
    echo "No handler for env : $1, exiting"
    exit 1
  fi
}

__save_service_config() {
  local service=$1
  local ports=$2
  local opts=$3
  local component=$4
  local job_type=$5

  __process_msg "Saving config for $service"
  local env_vars=$(cat $CONFIG_FILE | jq --arg service "$service" '
    .services[] |
    select (.name==$service) | .envs')
  __process_msg "Found envs for $service: $env_vars"

  local env_vars_count=$(echo $env_vars | jq '. | length')
  __process_msg "Successfully read from config.json: $service.envs ($env_vars_count)"

  env_values=""
  for i in $(seq 1 $env_vars_count); do
    local env_var=$(echo $env_vars | jq -r '.['"$i-1"']')
    __map_env_vars $env_var $component $job_type
    env_values="$env_values -e $env_var=$env_value"
  done

  local state_env=$(cat $STATE_FILE | jq --arg service "$service" '
    .services  |=
    map(if .name==$service then
        .env = "'$env_values'"
      else
        .
      end
    )'
  )
  update=$(echo $state_env | jq '.' | tee $STATE_FILE)


  __process_msg "Generating $service replicas"
  local replicas=$(cat $CONFIG_FILE | jq --arg service "$service" '
    .services[] |
    select (.name==$service) | .replicas')

  if [ $replicas != "null" ]; then
    __process_msg "Found $replicas for $service"
    local replicas_update=$(cat $STATE_FILE | jq --arg service "$service" '
      .services  |=
      map(if .name == $service then
          .replicas = "'$replicas'"
        else
          .
        end
      )'
    )
    update=$(echo $replicas_update | jq '.' | tee $STATE_FILE)
    __process_msg "Successfully updated $service replicas"
  fi

  # Ports
  __process_msg "Generating $service port mapping"
  # TODO: Fetch from systemConfig
  local port_mapping=$ports
  __process_msg "$service port mapping : $port_mapping"

  if [ ! -z $ports ]; then
    local port_update=$(cat $STATE_FILE | jq --arg service "$service" '
      .services  |=
      map(if .name == $service then
          .port = "'$port_mapping'"
        else
          .
        end
      )'
    )
    update=$(echo $port_update | jq '.' | tee $STATE_FILE)
    __process_msg "Successfully updated $service port mapping"
  fi

  # Opts
  __process_msg "Generating $service opts"
  # TODO: Fetch from systemConfig
  local opts=$3
  __process_msg "$service opts : $opts"

  if [ ! -z $opts ]; then
    local opt_update=$(cat $STATE_FILE | jq --arg service "$service" '
      .services  |=
      map(if .name == $service then
          .opts = "'$opts'"
        else
          .
        end
      )'
    )
    update=$(echo $opt_update | jq '.' | tee $STATE_FILE)
    __process_msg "Successfully updated $service opts"
  fi
}

_update_install_status() {
  local update=$(cat $STATE_FILE | jq '.installStatus.'"$1"'='true'')
  _update_state "$update"
}

__run_service() {
  service=$1
  __process_msg "Provisioning $service on swarm cluster"
  local swarm_manager_machine=$(cat $STATE_FILE | jq '.machines[] | select (.group=="core" and .name=="swarm")')
  local swarm_manager_host=$(echo $swarm_manager_machine | jq '.ip')

  local port_mapping=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .port')
  local env_variables=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .env')
  local name=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .name')
  local opts=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .opts')
  local image=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .image')
  local replicas=$(cat $STATE_FILE | jq --arg service "$service" -r '.services[] | select (.name==$service) | .replicas')

  local boot_cmd="sudo docker service create"

  if [ $port_mapping != "null" ]; then
    boot_cmd="$boot_cmd $port_mapping"
  fi

  if [ $env_variables != "null" ]; then
    boot_cmd="$boot_cmd $env_variables"
  fi

  if [ $replicas != "null" ]; then
    boot_cmd="$boot_cmd --replicas $replicas"
  else
    boot_cmd="$boot_cmd --mode global"
  fi

  if [ $opts != "null" ]; then
    boot_cmd="$boot_cmd $opts"
  fi

  boot_cmd="$boot_cmd $image"
  _update_install_status "${service}Installed"
  _update_install_status "${service}Initialized"
  _exec_remote_cmd "$swarm_manager_host" "docker service rm $service || true"
  _exec_remote_cmd "$swarm_manager_host" "$boot_cmd"
  __process_msg "Successfully provisioned $service"
}

provision_www() {
  __save_service_config www " --publish 50001:50001/tcp" " --name www --network ingress --with-registry-auth --endpoint-mode vip"
  __run_service "www"
}

provision_sync() {
  __save_service_config sync "" " --name sync --network ingress --with-registry-auth --endpoint-mode vip" "sync"
  __run_service "sync"
}

provision_ini() {
  __save_service_config ini " " " --name ini --network ingress --with-registry-auth --endpoint-mode vip" "ini"
  __run_service "ini"
}

provision_deploy() {
  __save_service_config deploy " " " --name deploy --network ingress --with-registry-auth --endpoint-mode vip" "stepExec" "deploy"
  __run_service "deploy"
}

provision_release() {
  __save_service_config release " " " --name release --network ingress --with-registry-auth --endpoint-mode vip" "stepExec" "release"
  __run_service "release"
}

provision_rSync() {
  __save_service_config rSync " " " --name rSync --network ingress --with-registry-auth --endpoint-mode vip" "stepExec" "rSync"
  __run_service "rSync"
}

provision_manifest() {
  __save_service_config manifest " " " --name manifest --network ingress --with-registry-auth --endpoint-mode vip" "stepExec" "manifest"
  __run_service "manifest"
}

provision_versionTrigger() {
  __save_service_config versionTrigger " " " --name versionTrigger --network ingress --with-registry-auth --endpoint-mode vip" "versionTrigger"
  __run_service "versionTrigger"
}

provision_certgen() {
  __save_service_config certgen " " " --name certgen --network ingress --with-registry-auth --endpoint-mode vip" "certgen"
  __run_service "certgen"
}

provision_charon() {
  __save_service_config charon " " " --name charon --network ingress --with-registry-auth --endpoint-mode vip" "charon"
  __run_service "charon"
}

provision_nexec() {
  __save_service_config nexec " " " --name nexec --network ingress --with-registry-auth --endpoint-mode vip" "nexec"
  __run_service "nexec"
}

provision_jobtrigger() {
  __save_service_config jobtrigger " " " --name jobtrigger --network ingress --with-registry-auth --endpoint-mode vip" "jobTrigger"
  __run_service "jobtrigger"
}

provision_jobrequest() {
  __save_service_config jobrequest " " " --name jobrequest --network ingress --with-registry-auth --endpoint-mode vip" "jobRequest"
  __run_service "jobrequest"
}

provision_cron() {
  __save_service_config cron " " " --name cron --network ingress --with-registry-auth --endpoint-mode vip" "cron"
  __run_service "cron"
}

provision_marshaller() {
  __save_service_config marshaller " " " --name marshaller --network ingress --with-registry-auth --endpoint-mode vip" "marshaller"
  __run_service "marshaller"
}

provision_sync() {
  __save_service_config sync "" " --name sync --network ingress --with-registry-auth --endpoint-mode vip" "sync"
  # The second argument will be used for $component
  __run_service "sync"
}

main() {
  __process_marker "Provisioning services"
  load_services
  provision_www
  provision_sync
  provision_ini
  provision_nexec
  provision_jobrequest
  provision_jobtrigger
  provision_marshaller
  provision_cron
  provision_deploy
  provision_release
  provision_rSync
  provision_manifest
  provision_versionTrigger
  provision_certgen
  provision_charon
}

main
