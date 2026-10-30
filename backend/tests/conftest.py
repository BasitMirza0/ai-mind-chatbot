"""Unit tests must never load developer credentials or the private dotenv file."""
from app.config import Settings

Settings.model_config['env_file'] = None
