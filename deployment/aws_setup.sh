#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

CONFIG_FILE="$PROJECT_ROOT/config/cloud.conf"

log() {
    printf '[INFO] %s\n' "$1"
}

fail() {
    printf '[ERROR] %s\n' "$1" >&2
    exit 1
}

check_prerequisites() {
    [[ -f "$CONFIG_FILE" ]] || fail "cloud.conf not found."

    command -v aws >/dev/null 2>&1 ||
        fail "AWS CLI is not installed."

    command -v python3 >/dev/null 2>&1 ||
        fail "Python 3 is required."
}

load_config() {
    source "$CONFIG_FILE"

    AWS_REGION="${AWS_REGION:-}"

    if [[ -z "$AWS_REGION" ]]; then
        AWS_REGION="$(aws configure get region 2>/dev/null || true)"
    fi

    [[ -n "$AWS_REGION" ]] ||
        fail "AWS region is missing. Configure AWS_REGION in cloud.conf or AWS CLI."

    [[ "$AWS_REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] ||
        fail "Invalid AWS region: $AWS_REGION"
}

check_identity() {
    local identity

    log "Checking AWS credentials..."

    if ! identity="$(aws sts get-caller-identity \
        --region "$AWS_REGION" \
        --query Arn \
        --output text 2>&1)"; then
        fail "AWS authentication failed: $identity"
    fi

    [[ -n "$identity" && "$identity" != "None" ]] ||
        fail "Could not determine AWS identity."

    log "AWS authentication successful."
    log "Active identity: $identity"
    log "AWS region: $AWS_REGION"
}

check_instance() {
    local details

    if [[ -z "${AWS_INSTANCE_ID:-}" ]]; then
        log "No EC2 instance ID configured."
        log "Skipping EC2 instance inspection."
        return
    fi

    [[ "$AWS_INSTANCE_ID" =~ ^i-[a-f0-9]+$ ]] ||
        fail "Invalid EC2 instance ID: $AWS_INSTANCE_ID"

    log "Inspecting configured EC2 instance..."

    if ! details="$(aws ec2 describe-instances \
        --instance-ids "$AWS_INSTANCE_ID" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].[InstanceType,State.Name,Placement.AvailabilityZone]' \
        --output text 2>&1)"; then
        fail "Could not inspect EC2 instance: $details"
    fi

    [[ -n "$details" && "$details" != "None" ]] ||
        fail "EC2 instance details were not returned."

    printf 'Instance details:\n%s\n' "$details"
}

main() {
    local command="${1:-check}"

    case "$command" in
        check)
            check_prerequisites
            load_config
            check_identity
            check_instance

            log "AWS pre-deployment checks completed."
            log "No AWS resources were created or modified."
            ;;
        *)
            printf 'Usage: %s [check]\n' "$0" >&2
            exit 1
            ;;
    esac
}

main "$@"
