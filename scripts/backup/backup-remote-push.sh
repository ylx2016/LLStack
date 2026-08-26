#!/bin/bash
set -euo pipefail

# Push backup file to remote storage (S3 or SFTP)
# Usage: backup-remote-push.sh --file <path> --type <s3|sftp> --config <json_file>

FILE=""
TYPE=""
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)   FILE="$2"; shift 2 ;;
        --type)   TYPE="$2"; shift 2 ;;
        --config) CONFIG_FILE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[[ -z "$FILE" || -z "$TYPE" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }
[[ ! -f "$FILE" ]] && { echo '{"ok":false,"error":"file_not_found"}' >&2; exit 1; }

# Cleanup credential temp file on exit.
# Only remove the file if the caller explicitly told us it is a temp file we own
# (--cleanup). Never delete a caller-supplied config file — it may be a persistent
# credentials file reused across scheduled pushes.
CLEANUP=false
trap 'if [[ "$CLEANUP" == true ]]; then rm -f -- "$CONFIG_FILE" 2>/dev/null || true; fi' EXIT

FILENAME=$(basename "$FILE")

# Safe config reader — pass file path as argv, not interpolated into code
read_config() {
    local key="$1"
    local default="${2:-}"
    python3 - "$CONFIG_FILE" "$key" "$default" << 'PYEOF'
import json, sys
config_file, key, default = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    config = json.load(open(config_file))
    print(config.get(key, default))
except Exception:
    print(default)
PYEOF
}

case "$TYPE" in
    s3)
        # Read config: endpoint, bucket, access_key, secret_key, region
        if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
            ENDPOINT=$(read_config endpoint "")
            BUCKET=$(read_config bucket "")
            ACCESS_KEY=$(read_config access_key "")
            SECRET_KEY=$(read_config secret_key "")
            REGION=$(read_config region "us-east-1")
        fi

        [[ -z "$BUCKET" ]] && { echo '{"ok":false,"error":"bucket_required"}' >&2; exit 1; }

        # Use aws cli
        if command -v aws &>/dev/null; then
            export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
            export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
            export AWS_DEFAULT_REGION="$REGION"
            EXTRA_ARGS=()
            [[ -n "$ENDPOINT" ]] && EXTRA_ARGS+=(--endpoint-url "$ENDPOINT")
            aws s3 cp "$FILE" "s3://$BUCKET/llstack-backups/$FILENAME" "${EXTRA_ARGS[@]}" >&2 2>&1
        else
            echo ">>> S3 upload requires aws-cli. Install: dnf install awscli" >&2
            exit 1
        fi
        ;;

    sftp)
        # Read config: host, port, user, key_file, remote_path
        if [[ -n "$CONFIG_FILE" && -f "$CONFIG_FILE" ]]; then
            HOST=$(read_config host "")
            PORT=$(read_config port "22")
            SFTP_USER=$(read_config user "root")
            KEY_FILE=$(read_config key_file "")
            REMOTE_PATH=$(read_config remote_path "/backups")
        fi

        [[ -z "$HOST" ]] && { echo '{"ok":false,"error":"host_required"}' >&2; exit 1; }

        SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -P "$PORT")
        [[ -n "$KEY_FILE" ]] && SSH_OPTS+=(-i "$KEY_FILE")

        sftp "${SSH_OPTS[@]}" "$SFTP_USER@$HOST" << SFTPEOF
mkdir "$REMOTE_PATH"
cd "$REMOTE_PATH"
put "$FILE"
SFTPEOF
        ;;

    *)
        echo '{"ok":false,"error":"unsupported_type"}' >&2
        exit 1
        ;;
esac

echo "{\"ok\":true,\"data\":{\"file\":\"$FILENAME\",\"type\":\"$TYPE\"}}"
