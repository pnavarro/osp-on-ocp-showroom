#!/bin/bash
# Shared credential parsing and inventory injection for RHOSO deploy scripts.

_cred_yaml_value() {
    local key="$1"
    local file="$2"
    grep "^${key}:" "$file" 2>/dev/null | head -1 | sed -E "s/^${key}: *[\"']?([^\"']*)[\"']?/\\1/"
}

_cred_yaml_bool() {
    local val
    val=$(_cred_yaml_value "$1" "$2")
    if [[ -z "$val" ]]; then
        echo "false"
    else
        echo "$val" | tr '[:upper:]' '[:lower:]'
    fi
}

_inject_credentials_with_python() {
    local inventory_file="$1"
    local payload="$2"
    local payload_file
    payload_file=$(mktemp)
    printf '%s' "$payload" > "$payload_file"
    python3 - "$inventory_file" "$payload_file" <<'PY'
import json
import re
import sys

path = sys.argv[1]
with open(sys.argv[2], encoding="utf-8") as handle:
    data = json.load(handle)
updates = data["updates"]

with open(path, encoding="utf-8") as handle:
    lines = handle.readlines()

insert_after = None
for index, line in enumerate(lines):
    if re.match(r"^\s*(registry_password|rhc_password|satellite_insecure|ocp4_workload_rhoso_deployment_rhc_activation_key):", line):
        insert_after = index

for key, value, quoted in updates:
    pattern = re.compile(rf"^(\s*{re.escape(key)}:)\s*.*$")
    found = False
    for index, line in enumerate(lines):
        match = pattern.match(line)
        if not match:
            continue
        prefix = match.group(1)
        if quoted:
            lines[index] = f'{prefix} "{value}"\n'
        else:
            lines[index] = f"{prefix} {value}\n"
        found = True
        break

    if found:
        continue

    if insert_after is None:
        for index, line in enumerate(lines):
            if re.match(r"^\s*vars:\s*$", line):
                insert_after = index
                break

    if insert_after is None:
        raise SystemExit(f"[ERROR] Could not find insertion point for inventory key: {key}")

    indent_match = re.match(r"^(\s*)", lines[insert_after])
    indent = indent_match.group(1) if indent_match else "    "
    if quoted:
        new_line = f'{indent}{key}: "{value}"\n'
    else:
        new_line = f"{indent}{key}: {value}\n"
    lines.insert(insert_after + 1, new_line)
    insert_after += 1

with open(path, "w", encoding="utf-8") as handle:
    handle.writelines(lines)
PY
    rm -f "$payload_file"
}

# Parse credentials.yml and export CRED_* variables.
# Sets CRED_SUBSCRIPTION_MODE to "satellite" or "portal".
parse_credentials_file() {
    local credentials_file="$1"

    if [[ ! -f "$credentials_file" ]]; then
        echo "[ERROR] Credentials file not found: $credentials_file" >&2
        exit 1
    fi

    echo "[INFO] Loading credentials from: $credentials_file"

    export CRED_REGISTRY_USERNAME=$(_cred_yaml_value registry_username "$credentials_file")
    export CRED_REGISTRY_PASSWORD=$(_cred_yaml_value registry_password "$credentials_file")
    export CRED_RHC_USERNAME=$(_cred_yaml_value rhc_username "$credentials_file")
    export CRED_RHC_PASSWORD=$(_cred_yaml_value rhc_password "$credentials_file")
    export CRED_SATELLITE_URL=$(_cred_yaml_value satellite_url "$credentials_file")
    export CRED_SATELLITE_ORG=$(_cred_yaml_value satellite_org "$credentials_file")
    export CRED_RHC_ACTIVATION_KEY=$(_cred_yaml_value ocp4_workload_rhoso_deployment_rhc_activation_key "$credentials_file")
    export CRED_SATELLITE_INSECURE=$(_cred_yaml_bool satellite_insecure "$credentials_file")

    if [[ -z "$CRED_REGISTRY_USERNAME" || -z "$CRED_REGISTRY_PASSWORD" ]]; then
        echo "[ERROR] Missing required registry credentials in file: $credentials_file" >&2
        echo "Required fields: registry_username, registry_password" >&2
        exit 1
    fi

    local portal_mode=false
    local satellite_mode=false

    if [[ -n "$CRED_RHC_USERNAME" && -n "$CRED_RHC_PASSWORD" ]]; then
        portal_mode=true
    fi
    if [[ -n "$CRED_SATELLITE_URL" ]]; then
        satellite_mode=true
    fi

    if [[ "$portal_mode" == true && "$satellite_mode" == true ]]; then
        echo "[ERROR] Conflicting subscription credentials in file: $credentials_file" >&2
        echo "Use either Customer Portal (rhc_username + rhc_password) OR Satellite" >&2
        echo "(satellite_url + satellite_org + ocp4_workload_rhoso_deployment_rhc_activation_key), not both." >&2
        exit 1
    fi

    if [[ "$satellite_mode" == true ]]; then
        if [[ -z "$CRED_SATELLITE_ORG" || -z "$CRED_RHC_ACTIVATION_KEY" ]]; then
            echo "[ERROR] Incomplete Satellite credentials in file: $credentials_file" >&2
            echo "Satellite mode requires: satellite_url, satellite_org," >&2
            echo "ocp4_workload_rhoso_deployment_rhc_activation_key" >&2
            exit 1
        fi
        export CRED_SUBSCRIPTION_MODE=satellite
        export CRED_RHC_USERNAME=""
        export CRED_RHC_PASSWORD=""
    elif [[ "$portal_mode" == true ]]; then
        export CRED_SUBSCRIPTION_MODE=portal
    else
        echo "[ERROR] Missing subscription credentials in file: $credentials_file" >&2
        echo "Provide either Customer Portal (rhc_username + rhc_password) or Satellite" >&2
        echo "(satellite_url + satellite_org + ocp4_workload_rhoso_deployment_rhc_activation_key)." >&2
        exit 1
    fi

    echo "[INFO] Credentials loaded successfully"
    echo "[INFO] Registry username: ${CRED_REGISTRY_USERNAME%%|*}|***"
    echo "[INFO] Subscription mode: $CRED_SUBSCRIPTION_MODE"
    if [[ "$CRED_SUBSCRIPTION_MODE" == portal ]]; then
        echo "[INFO] RHC username: $CRED_RHC_USERNAME"
    else
        echo "[INFO] Satellite URL: $CRED_SATELLITE_URL"
        echo "[INFO] Satellite org: $CRED_SATELLITE_ORG"
    fi
}

# Inject parsed credentials into an inventory file (in-place).
inject_credentials_into_inventory() {
    local inventory_file="$1"

    if [[ ! -f "$inventory_file" ]]; then
        echo "[ERROR] Inventory file not found: $inventory_file" >&2
        exit 1
    fi

    if [[ -z "${CRED_REGISTRY_USERNAME:-}" ]]; then
        return 0
    fi

    echo "[INFO] Injecting credentials into inventory: $inventory_file"

    local payload
    if [[ "${CRED_SUBSCRIPTION_MODE:-}" == satellite ]]; then
        payload=$(CRED_REGISTRY_USERNAME="$CRED_REGISTRY_USERNAME" \
            CRED_REGISTRY_PASSWORD="$CRED_REGISTRY_PASSWORD" \
            CRED_SATELLITE_URL="$CRED_SATELLITE_URL" \
            CRED_SATELLITE_ORG="$CRED_SATELLITE_ORG" \
            CRED_RHC_ACTIVATION_KEY="$CRED_RHC_ACTIVATION_KEY" \
            CRED_SATELLITE_INSECURE="$CRED_SATELLITE_INSECURE" \
            python3 - <<'PY'
import json
import os

updates = [
    ("registry_username", os.environ["CRED_REGISTRY_USERNAME"], True),
    ("registry_password", os.environ["CRED_REGISTRY_PASSWORD"], True),
    ("satellite_url", os.environ["CRED_SATELLITE_URL"], True),
    ("satellite_org", os.environ["CRED_SATELLITE_ORG"], True),
    ("ocp4_workload_rhoso_deployment_rhc_activation_key", os.environ["CRED_RHC_ACTIVATION_KEY"], True),
    ("satellite_insecure", os.environ.get("CRED_SATELLITE_INSECURE", "false"), False),
    ("rhc_username", "", True),
    ("rhc_password", "", True),
]
print(json.dumps({"updates": updates}))
PY
)
    else
        payload=$(CRED_REGISTRY_USERNAME="$CRED_REGISTRY_USERNAME" \
            CRED_REGISTRY_PASSWORD="$CRED_REGISTRY_PASSWORD" \
            CRED_RHC_USERNAME="$CRED_RHC_USERNAME" \
            CRED_RHC_PASSWORD="$CRED_RHC_PASSWORD" \
            python3 - <<'PY'
import json
import os

updates = [
    ("registry_username", os.environ["CRED_REGISTRY_USERNAME"], True),
    ("registry_password", os.environ["CRED_REGISTRY_PASSWORD"], True),
    ("rhc_username", os.environ["CRED_RHC_USERNAME"], True),
    ("rhc_password", os.environ["CRED_RHC_PASSWORD"], True),
    ("satellite_url", "", True),
    ("satellite_org", "", True),
    ("ocp4_workload_rhoso_deployment_rhc_activation_key", "", True),
    ("satellite_insecure", "false", False),
]
print(json.dumps({"updates": updates}))
PY
)
    fi

    _inject_credentials_with_python "$inventory_file" "$payload"

    echo "[INFO] Credentials injected into inventory"
}
