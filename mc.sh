#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IP_FILE="${ROOT_DIR}/.mc-public-ip"
CLUSTER_NAME="mc"
SERVICE_NAME="minecraft"

load_env() {
  local env_file="${ROOT_DIR}/.env.aws"

  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${env_file}"
    set +a
  elif [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
    :
  else
    echo "Missing AWS credentials."
    echo "Create ${env_file} from .env.aws.example, or export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
    exit 1
  fi

  export AWS_DEFAULT_REGION=us-east-1
  export AWS_PAGER=""
}

install_ansible_collections() {
  ansible-galaxy collection install -r "${ROOT_DIR}/ansible/requirements.yml"
}

run_playbook() {
  local playbook="$1"
  ansible-playbook -i localhost, -e ansible_connection=local "${ROOT_DIR}/ansible/${playbook}"
}

read_public_ip() {
  if [[ ! -f "${IP_FILE}" ]]; then
    echo "No public IP file. Run ./mc.sh deploy first." >&2
    return 1
  fi

  tr -d '[:space:]' < "${IP_FILE}"
}

refresh_public_ip() {
  local task_arn eni_id public_ip

  task_arn="$(aws ecs list-tasks \
    --cluster "${CLUSTER_NAME}" \
    --service-name "${SERVICE_NAME}" \
    --desired-status RUNNING \
    --query 'taskArns[0]' \
    --output text)"

  eni_id="$(aws ecs describe-tasks \
    --cluster "${CLUSTER_NAME}" \
    --tasks "${task_arn}" \
    --query 'tasks[0].attachments[?type==`ElasticNetworkInterface`] | [0].details[?name==`networkInterfaceId`].value | [0]' \
    --output text)"

  public_ip="$(aws ec2 describe-network-interfaces \
    --network-interface-ids "${eni_id}" \
    --query 'NetworkInterfaces[0].Association.PublicIp' \
    --output text)"

  printf '%s\n' "${public_ip}" > "${IP_FILE}"
  echo "Public IP: ${public_ip}"
}

cmd_deploy() {
  load_env
  install_ansible_collections
  run_playbook deploy.yml
}

cmd_test() {
  local public_ip

  load_env
  public_ip="$(read_public_ip)"
  if [[ -z "${public_ip}" || "${public_ip}" == "None" ]]; then
    echo "Could not determine the Minecraft server public IP."
    exit 1
  fi
  nmap -sV -Pn -p T:25565 "${public_ip}"
}

cmd_restart() {
  local task_arn

  load_env

  task_arn="$(aws ecs list-tasks \
    --cluster "${CLUSTER_NAME}" \
    --service-name "${SERVICE_NAME}" \
    --desired-status RUNNING \
    --query 'taskArns[0]' \
    --output text)"

  if [[ -z "${task_arn}" || "${task_arn}" == "None" ]]; then
    echo "No running task found to stop."
    exit 1
  fi

  aws ecs stop-task \
    --cluster "${CLUSTER_NAME}" \
    --task "${task_arn}" \
    --reason "Restart test"

  aws ecs wait services-stable \
    --cluster "${CLUSTER_NAME}" \
    --services "${SERVICE_NAME}"

  refresh_public_ip
  cmd_test
}

cmd_destroy() {
  load_env
  install_ansible_collections
  run_playbook destroy.yml
}

usage() {
  cat <<EOF
Available Commands:
  deploy   Provision th AWS infrastructure and start the Minecraft server
  test     Run nmap against the server on TCP 25565
  restart  Stop the running task and verify ECS starts a replacement
  destroy  Tear down all Ansible resources
EOF
}

main() {
  case "${1:-}" in
    deploy) cmd_deploy ;;
    test) cmd_test ;;
    restart) cmd_restart ;;
    destroy) cmd_destroy ;;
    -h|--help|help) usage ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
