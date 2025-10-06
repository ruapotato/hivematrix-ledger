#!/bin/bash
#
# HiveMatrix Ledger - Installation Script
# Handles setup of billing and invoicing system
#

set -e  # Exit on error

APP_NAME="ledger"
APP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PARENT_DIR="$(dirname "$APP_DIR")"
HELM_DIR="$PARENT_DIR/hivematrix-helm"

echo "=========================================="
echo "  Installing HiveMatrix Ledger"
echo "=========================================="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Parse command line arguments
DB_NAME="ledger_db"
DB_USER="ledger_user"
DB_PASSWORD=""
CODEX_URL="http://localhost:5010"

while [[ $# -gt 0 ]]; do
    case $1 in
        --db-name)
            DB_NAME="$2"
            shift 2
            ;;
        --db-user)
            DB_USER="$2"
            shift 2
            ;;
        --db-password)
            DB_PASSWORD="$2"
            shift 2
            ;;
        --codex-url)
            CODEX_URL="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

# Generate password if not provided
if [ -z "$DB_PASSWORD" ]; then
    DB_PASSWORD=$(openssl rand -base64 24 | tr -d "=+/" | cut -c1-24)
fi

# Check Python version
echo -e "${YELLOW}Checking Python...${NC}"
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}✗ Python 3 not found${NC}"
    echo "Please install Python 3.8 or higher"
    exit 1
fi

PYTHON_VERSION=$(python3 --version | awk '{print $2}')
echo -e "${GREEN}✓ Found Python $PYTHON_VERSION${NC}"
echo ""

# Create virtual environment
echo -e "${YELLOW}Creating virtual environment...${NC}"
if [ -d "pyenv" ]; then
    echo "  Virtual environment already exists"
else
    python3 -m venv pyenv
    echo -e "${GREEN}✓ Virtual environment created${NC}"
fi
echo ""

# Activate virtual environment
source pyenv/bin/activate

# Upgrade pip
echo -e "${YELLOW}Upgrading pip...${NC}"
pip install --upgrade pip > /dev/null 2>&1
echo -e "${GREEN}✓ pip upgraded${NC}"
echo ""

# Install dependencies
if [ -f "requirements.txt" ]; then
    echo -e "${YELLOW}Installing Python dependencies...${NC}"
    pip install -r requirements.txt
    echo -e "${GREEN}✓ Dependencies installed${NC}"
    echo ""
fi

# Create instance directory if needed
if [ ! -d "instance" ]; then
    echo -e "${YELLOW}Creating instance directory...${NC}"
    mkdir -p instance
    echo -e "${GREEN}✓ Instance directory created${NC}"
    echo ""
fi

# === LEDGER-SPECIFIC SETUP ===
echo -e "${YELLOW}Running Ledger-specific setup...${NC}"

# 1. Setup PostgreSQL database
echo "Setting up PostgreSQL database..."

# Check if database exists
DB_EXISTS=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" 2>/dev/null || echo "0")

if [ "$DB_EXISTS" != "1" ]; then
    echo "Creating database $DB_NAME..."

    # Create database and user
    sudo -u postgres psql <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
EOF

    # Grant schema permissions (PostgreSQL 15+)
    sudo -u postgres psql -d $DB_NAME <<EOF
GRANT ALL ON SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $DB_USER;
EOF

    echo -e "${GREEN}✓ Database created${NC}"
else
    echo "Database $DB_NAME already exists"
fi
echo ""

# 2. Initialize database schema
echo "Initializing database schema..."

# Create .flaskenv
cat > .flaskenv <<EOF
FLASK_APP=run.py
FLASK_ENV=development
SERVICE_NAME=ledger

# Database
DB_HOST=localhost
DB_PORT=5432
DB_NAME=$DB_NAME
DB_USER=$DB_USER

# Services
CORE_SERVICE_URL=http://localhost:5000
CODEX_SERVICE_URL=$CODEX_URL

# Keycloak
KEYCLOAK_URL=http://localhost:8080
KEYCLOAK_REALM=hivematrix
KEYCLOAK_CLIENT_ID=core-client
EOF

# Create instance config
cat > instance/ledger.conf <<EOF
[database]
connection_string = postgresql://$DB_USER:$DB_PASSWORD@localhost:5432/$DB_NAME
db_host = localhost
db_port = 5432
db_name = $DB_NAME
db_user = $DB_USER

[services]
codex_url = $CODEX_URL
core_url = http://localhost:5000
EOF

# Initialize database if init_db.py exists
if [ -f "init_db.py" ]; then
    echo "Running database initialization..."
    DB_PASSWORD="$DB_PASSWORD" python init_db.py --non-interactive || echo "Note: Database may already be initialized"

    # Run SQL migrations if they exist
    if [ -f "migrations/schema.sql" ]; then
        echo "Running SQL migrations..."
        PGPASSWORD="$DB_PASSWORD" psql -h localhost -U $DB_USER -d $DB_NAME -f migrations/schema.sql 2>/dev/null || true
    fi

    # Create default billing plans
    if [ -f "migrations/default_billing_plans.sql" ]; then
        echo "Creating default billing plans..."
        PGPASSWORD="$DB_PASSWORD" psql -h localhost -U $DB_USER -d $DB_NAME -f migrations/default_billing_plans.sql 2>/dev/null || true
    fi

    echo -e "${GREEN}✓ Database schema initialized${NC}"
fi
echo ""

# 3. Sync configuration from Helm (if Helm is installed)
if [ -d "$HELM_DIR" ] && [ -f "$HELM_DIR/config_manager.py" ]; then
    echo "Syncing configuration from Helm..."
    cd "$HELM_DIR"
    source pyenv/bin/activate 2>/dev/null || true

    # Update Helm's master config with Ledger settings
    python -c "
from config_manager import ConfigManager
cm = ConfigManager()
cm.update_app_config('ledger', {
    'database': 'postgresql',
    'db_name': '$DB_NAME',
    'db_user': '$DB_USER',
    'db_password': '$DB_PASSWORD',
    'sections': {
        'services': {
            'codex_url': '$CODEX_URL',
            'core_url': 'http://localhost:5000'
        }
    }
})
" 2>/dev/null || true

    # Write updated config back to Ledger
    python config_manager.py write-dotenv ledger 2>/dev/null || true
    python config_manager.py write-conf ledger 2>/dev/null || true

    cd "$APP_DIR"
    echo -e "${GREEN}✓ Configuration synced${NC}"
    echo ""
fi

# 4. Create export directories
echo "Creating export directories..."
mkdir -p exports/{quickbooks,csv,zip}
echo -e "${GREEN}✓ Export directories created${NC}"
echo ""

echo -e "${GREEN}✓ Ledger-specific setup complete${NC}"
echo ""

echo "=========================================="
echo -e "${GREEN}  Ledger installed successfully!${NC}"
echo "=========================================="
echo ""
echo "Database Configuration:"
echo "  Database: $DB_NAME"
echo "  User: $DB_USER"
echo "  Password: $DB_PASSWORD"
echo ""
echo "Service Configuration:"
echo "  Codex URL: $CODEX_URL"
echo "  Core URL: http://localhost:5000"
echo ""
echo "Next steps:"
echo "  1. Ensure Codex is running and accessible"
echo "  2. Start Ledger: python run.py"
echo "  3. Or use Helm to start all services"
echo "  4. Configure billing plans via dashboard"
echo "  5. Add client billing overrides as needed"
echo ""
