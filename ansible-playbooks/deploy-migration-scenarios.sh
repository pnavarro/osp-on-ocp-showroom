#!/bin/bash
# Deploy migration scenario(s) – create job templates in AAP
# Run after AAP base configuration (e.g. migration-setup.yml --tags configure-aap-for-migration).
# Uses migration-scenarios.yml and vars/migration.yml (migration_scenarios list).

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INVENTORY=""
CREDENTIALS=""
TAGS=""
SKIP_TAGS=""
VERBOSE=""
PLAYBOOK="migration-scenarios.yml"

usage() {
    cat << EOF
Usage: $0 --inventory <inventory_file> --credentials <credentials_file> [OPTIONS]

Deploy migration scenario(s) – create job templates in Ansible Automation Platform.
Requires AAP to be installed and base-configured (credentials, inventory, project, EE).
Which scenarios run is controlled by migration_scenarios in vars/migration.yml.

Required Arguments:
  --inventory <file>       Path to inventory file (e.g., inventory/hosts-<guid>.yml)
  --credentials <file>     Path to credentials file (e.g., credentials.yml)

Optional Arguments:
  --tags <tags>           Run only tasks with specific tags (e.g. migration-scenarios)
  --skip-tags <tags>      Skip tasks with specific tags
  -v, --verbose           Enable verbose output
  -h, --help              Display this help message

Examples:
  $0 --inventory inventory/hosts-abc123.yml --credentials credentials.yml
  $0 --inventory inventory/hosts-abc123.yml --credentials credentials.yml -v

Related:
  # Configure AAP base first (if not done yet)
  ./deploy-migration-setup.sh --inventory <inv> --credentials <cred> --configure-aap

  # Or run scenario playbook directly
  ansible-playbook -i inventory/hosts-abc123.yml $PLAYBOOK -e @credentials.yml

EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --inventory)
            INVENTORY="$2"
            shift 2
            ;;
        --credentials)
            CREDENTIALS="$2"
            shift 2
            ;;
        --tags)
            TAGS="$2"
            shift 2
            ;;
        --skip-tags)
            SKIP_TAGS="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE="-vvv"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option $1${NC}"
            usage
            ;;
    esac
done

if [[ -z "$INVENTORY" ]]; then
    echo -e "${RED}Error: --inventory is required${NC}"
    usage
fi
if [[ -z "$CREDENTIALS" ]]; then
    echo -e "${RED}Error: --credentials is required${NC}"
    usage
fi
if [[ ! -f "$INVENTORY" ]]; then
    echo -e "${RED}Error: Inventory file not found: $INVENTORY${NC}"
    exit 1
fi
if [[ ! -f "$CREDENTIALS" ]]; then
    echo -e "${RED}Error: Credentials file not found: $CREDENTIALS${NC}"
    exit 1
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Deploy migration scenario(s)${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "Inventory:   $INVENTORY"
echo -e "Credentials: $CREDENTIALS"
echo -e "Playbook:    $PLAYBOOK"
[[ -n "$TAGS" ]] && echo -e "Tags:        $TAGS"
[[ -n "$SKIP_TAGS" ]] && echo -e "Skip tags:   $SKIP_TAGS"
echo -e "${GREEN}========================================${NC}"
echo ""

if [[ -f "requirements.yml" ]]; then
    echo -e "${YELLOW}Installing required Ansible collections...${NC}"
    ansible-galaxy collection install -r requirements.yml
    echo -e "${GREEN}✓ Collections installed${NC}"
    echo ""
fi

ANSIBLE_CMD="ansible-playbook -i $INVENTORY $PLAYBOOK -e @$CREDENTIALS"
[[ -n "$TAGS" ]] && ANSIBLE_CMD="$ANSIBLE_CMD --tags $TAGS"
[[ -n "$SKIP_TAGS" ]] && ANSIBLE_CMD="$ANSIBLE_CMD --skip-tags $SKIP_TAGS"
[[ -n "$VERBOSE" ]] && ANSIBLE_CMD="$ANSIBLE_CMD $VERBOSE"

echo -e "${YELLOW}Executing:${NC} $ANSIBLE_CMD"
echo ""
eval $ANSIBLE_CMD
STATUS=$?

echo ""
if [[ $STATUS -eq 0 ]]; then
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Migration scenario(s) deployed successfully.${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo -e "${YELLOW}Next:${NC} Open AAP → Resources → Templates → launch your scenario job template."
    echo ""
    exit 0
else
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}Deployment failed.${NC}"
    echo -e "${RED}========================================${NC}"
    exit 1
fi
