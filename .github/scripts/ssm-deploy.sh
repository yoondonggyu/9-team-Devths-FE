#!/usr/bin/env bash
# GitHub Actions(OIDC로 AWS 인증된 상태)에서 실행 — SSM Send-Command로
# 지정한 EC2 인스턴스에 "이미지 pull + 재기동 + 헬스체크" 원격 실행.
#
# 사용법:
#   ssm-deploy.sh <인스턴스 Name 태그> <이미지 URI> <포트> <헬스체크 경로> <컨테이너 이름> \
#                 [추가 docker run 옵션] [DB_SECRET_ARN] [DB_ENDPOINT] [APP_SECRET_ARN] [RABBITMQ_SECRET_ARN]
#
# DB_SECRET_ARN/APP_SECRET_ARN/RABBITMQ_SECRET_ARN을 주면, 실제 값은 GitHub/SSM 페이로드를
# 거치지 않고 인스턴스 자신의 IAM 권한으로 Secrets Manager에서 직접 조회해 --env-file로
# 주입한다(워크플로우 YAML이나 SSM 커맨드 페이로드에 평문 노출 안 됨).
set -euo pipefail

INSTANCE_NAME="$1"
IMAGE_URI="$2"
CONTAINER_PORT="$3"
HEALTH_PATH="$4"
CONTAINER_NAME="$5"
EXTRA_ARGS="${6:-}"
DB_SECRET_ARN="${7:-}"
DB_ENDPOINT="${8:-}"
APP_SECRET_ARN="${9:-}"
RABBITMQ_SECRET_ARN="${10:-}"

AWS_REGION="ap-northeast-2"
ECR_REGISTRY="${IMAGE_URI%%/*}"

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

if [ "$INSTANCE_ID" = "None" ] || [ -z "$INSTANCE_ID" ]; then
  echo "인스턴스를 찾을 수 없습니다: $INSTANCE_NAME"
  exit 1
fi

echo "대상: $INSTANCE_NAME ($INSTANCE_ID)"

REMOTE_SCRIPT=$(cat <<EOS
#!/bin/bash
set -euo pipefail
command -v jq >/dev/null 2>&1 || dnf install -y -q jq

aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY}
docker pull ${IMAGE_URI}

# 시크릿은 -e 플래그로 직접 조립하지 않고 임시 env 파일에 모아 --env-file로 전달한다
# (값 안에 파이프/따옴표/개행 등 셸에 위험한 문자가 있어도 안전하게 처리하려는 목적 —
# Firebase 서비스 계정 JSON의 private_key처럼 긴 값이 대표적).
ENV_FILE=\$(mktemp)
trap 'rm -f "\$ENV_FILE"' EXIT

if [ -n "${DB_SECRET_ARN}" ]; then
  aws secretsmanager get-secret-value --secret-id "${DB_SECRET_ARN}" --region ${AWS_REGION} --query SecretString --output text \\
    | jq -r '"DB_USERNAME=" + .username, "DB_PASSWORD_V2=" + .password' >> "\$ENV_FILE"
  echo "DB_URL_V2=jdbc:postgresql://${DB_ENDPOINT}/devths" >> "\$ENV_FILE"
fi

if [ -n "${APP_SECRET_ARN}" ]; then
  aws secretsmanager get-secret-value --secret-id "${APP_SECRET_ARN}" --region ${AWS_REGION} --query SecretString --output text \\
    | jq -r 'to_entries[] | .key + "=" + .value' >> "\$ENV_FILE"
fi

if [ -n "${RABBITMQ_SECRET_ARN}" ]; then
  aws secretsmanager get-secret-value --secret-id "${RABBITMQ_SECRET_ARN}" --region ${AWS_REGION} --query SecretString --output text \\
    | jq -r '"SPRING_RABBITMQ_USERNAME=" + .username, "SPRING_RABBITMQ_PASSWORD=" + .password' >> "\$ENV_FILE"
fi

docker stop ${CONTAINER_NAME} 2>/dev/null || true
docker rm ${CONTAINER_NAME} 2>/dev/null || true

docker run -d --name ${CONTAINER_NAME} --restart unless-stopped \\
  -p ${CONTAINER_PORT}:${CONTAINER_PORT} \\
  --env-file "\$ENV_FILE" \\
  ${EXTRA_ARGS} \\
  ${IMAGE_URI}

for i in \$(seq 1 40); do
  sleep 3
  if curl -fsS "http://localhost:${CONTAINER_PORT}${HEALTH_PATH}"; then
    echo "헬스체크 통과"
    exit 0
  fi
done
echo "헬스체크 실패"
docker logs --tail 100 ${CONTAINER_NAME} || true
exit 1
EOS
)

# AWS CLI의 --parameters shorthand 문법은 스크립트 안의 파이프(|)/콤마/따옴표 등
# 특수문자를 만나면 값을 잘못 쪼개는 경우가 있어(실제로 이 버그로 dnf install에
# --region 플래그가 잘못 붙어 실패했음), shorthand 파싱을 완전히 우회하고
# JSON 파일로 파라미터를 넘긴다.
PARAMS_FILE=$(mktemp)
trap 'rm -f "$PARAMS_FILE"' EXIT
jq -n --arg script "$REMOTE_SCRIPT" '{commands: [$script]}' > "$PARAMS_FILE"

COMMAND_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --parameters "file://${PARAMS_FILE}" \
  --timeout-seconds 300 \
  --query "Command.CommandId" --output text)

echo "SSM Command ID: $COMMAND_ID"
sleep 3

while true; do
  STATUS=$(aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
    --query "Status" --output text 2>/dev/null || echo "Pending")
  echo "상태: $STATUS"
  case "$STATUS" in
    Success)
      break
      ;;
    Failed | Cancelled | TimedOut)
      echo "── stdout ──"
      aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
        --query "StandardOutputContent" --output text
      echo "── stderr ──"
      aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" \
        --query "StandardErrorContent" --output text
      exit 1
      ;;
  esac
  sleep 5
done

echo "배포 성공: $INSTANCE_NAME"
