"""Configuration loader and logging setup.

# LEGACY AP-01: database credentials live in a plaintext INI file on disk
# (/etc/shiptrack/app.ini, mode 0644), rendered by user-data from the migrator secret.
"""

from __future__ import annotations

import configparser
import logging
import os
from dataclasses import dataclass
from pathlib import Path

from sqlalchemy.engine import URL

DEFAULT_CONFIG_PATH = Path("/etc/shiptrack/app.ini")
CONFIG_ENV_VAR = "SHIPTRACK_CONFIG"
DEFAULT_POD_DIR = Path("/var/lib/shiptrack/pod")


class ConfigError(Exception):
    """The configuration file is missing or incomplete."""


@dataclass(frozen=True)
class Settings:
    db_host: str
    db_port: int
    db_name: str
    db_user: str
    db_password: str
    db_sslmode: str = "require"
    pod_dir: Path = DEFAULT_POD_DIR
    log_file: Path | None = None
    log_level: str = "INFO"

    @property
    def database_url(self) -> URL:
        # A URL object (not a string) so passwords never need escaping.
        return URL.create(
            "postgresql+psycopg",
            username=self.db_user,
            password=self.db_password,
            host=self.db_host,
            port=self.db_port,
            database=self.db_name,
            query={"sslmode": self.db_sslmode},
        )


def load_settings(path: Path | None = None) -> Settings:
    """Read settings from the INI file (path argument, then SHIPTRACK_CONFIG, then default)."""
    config_path = path or Path(os.environ.get(CONFIG_ENV_VAR, str(DEFAULT_CONFIG_PATH)))
    # interpolation=None: passwords may contain "%".
    parser = configparser.ConfigParser(interpolation=None)
    if not parser.read(config_path):
        raise ConfigError(f"configuration file not found: {config_path}")
    try:
        database = parser["database"]
        app = parser["app"] if parser.has_section("app") else {}
        log_file = app.get("log_file", "").strip()
        return Settings(
            db_host=database["host"],
            db_port=int(database.get("port", "5432")),
            db_name=database["name"],
            db_user=database["user"],
            db_password=database["password"],
            db_sslmode=database.get("sslmode", "require"),
            pod_dir=Path(app.get("pod_dir", str(DEFAULT_POD_DIR))),
            log_file=Path(log_file) if log_file else None,
            log_level=app.get("log_level", "INFO").upper(),
        )
    except KeyError as exc:
        raise ConfigError(f"missing configuration key: {exc.args[0]}") from exc
    except ValueError as exc:
        raise ConfigError(f"invalid configuration value: {exc}") from exc


def configure_logging(settings: Settings) -> None:
    """Plain-text logging.

    # LEGACY AP-08: unstructured text logs written to files and tailed by the CloudWatch
    # agent; there is no request ID, so a single request cannot be correlated across lines.
    """
    handlers: list[logging.Handler] = [logging.StreamHandler()]
    if settings.log_file is not None:
        handlers.append(logging.FileHandler(settings.log_file))
    logging.basicConfig(
        level=settings.log_level,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
        handlers=handlers,
        force=True,
    )
