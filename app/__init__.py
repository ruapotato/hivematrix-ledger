from flask import Flask
import json
import os
import secrets

app = Flask(__name__, instance_relative_config=True)

# Set secret key for sessions (generate a random one if not set)
app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY') or secrets.token_hex(32)

# Enable template auto-reload for development
app.config['TEMPLATES_AUTO_RELOAD'] = True

# --- Explicitly load all required configuration from environment variables ---
# Provide sensible defaults for init_db.py, will be overridden by Helm's .flaskenv
app.config['CORE_SERVICE_URL'] = os.environ.get('CORE_SERVICE_URL', 'http://localhost:5000')
app.config['SERVICE_NAME'] = os.environ.get('SERVICE_NAME', 'ledger')

# Load database connection from config file
import configparser
try:
    os.makedirs(app.instance_path)
except OSError:
    pass

config_path = os.path.join(app.instance_path, 'ledger.conf')
# Use RawConfigParser to avoid interpolation issues with special characters like %
config = configparser.RawConfigParser()
config.read(config_path)
app.config['LEDGER_CONFIG'] = config

# Database configuration
app.config['SQLALCHEMY_DATABASE_URI'] = config.get('database', 'connection_string',
    fallback=f"sqlite:///{os.path.join(app.instance_path, 'ledger.db')}")
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

# Load services configuration for service-to-service calls
try:
    with open('services.json') as f:
        services_config = json.load(f)
        app.config['SERVICES'] = services_config
except FileNotFoundError:
    print("WARNING: services.json not found. Service-to-service calls will not work.")
    app.config['SERVICES'] = {}

from extensions import db
db.init_app(app)

# Apply middleware to handle URL prefix when behind Nexus proxy
from app.middleware import PrefixMiddleware
app.wsgi_app = PrefixMiddleware(app.wsgi_app, prefix=f'/{app.config["SERVICE_NAME"]}')

# Register blueprints
from app.admin_routes import admin_bp
from app.api_routes import api_bp
app.register_blueprint(admin_bp)
app.register_blueprint(api_bp)

# Initialize Helm logger for centralized logging
app.config["SERVICE_NAME"] = os.environ.get("SERVICE_NAME", "ledger")
app.config["HELM_SERVICE_URL"] = os.environ.get("HELM_SERVICE_URL", "http://localhost:5004")

from app.helm_logger import init_helm_logger
helm_logger = init_helm_logger(
    app.config["SERVICE_NAME"],
    app.config["HELM_SERVICE_URL"]
)

from app import routes

# Log service startup
helm_logger.info(f"{app.config["SERVICE_NAME"]} service started")
