from pathlib import Path

import pytest

from shiptrack.config import CONFIG_ENV_VAR, ConfigError, load_settings

MINIMAL = """\
[database]
host = db.example.internal
name = shiptrack
user = shiptrack_migrator
password = p%ss#word
"""


def write(tmp_path: Path, text: str) -> Path:
    path = tmp_path / "app.ini"
    path.write_text(text)
    return path


def test_defaults(tmp_path: Path) -> None:
    settings = load_settings(write(tmp_path, MINIMAL))
    assert settings.db_port == 5432
    assert settings.db_sslmode == "require"
    assert settings.pod_dir == Path("/var/lib/shiptrack/pod")
    assert settings.log_file is None
    assert settings.log_level == "INFO"


def test_percent_characters_in_the_password_survive(tmp_path: Path) -> None:
    settings = load_settings(write(tmp_path, MINIMAL))
    assert settings.db_password == "p%ss#word"
    assert settings.database_url.password == "p%ss#word"


def test_app_section_overrides(tmp_path: Path) -> None:
    text = MINIMAL + "\n[app]\npod_dir = /data/pod\nlog_file = /tmp/app.log\nlog_level = debug\n"
    settings = load_settings(write(tmp_path, text))
    assert settings.pod_dir == Path("/data/pod")
    assert settings.log_file == Path("/tmp/app.log")
    assert settings.log_level == "DEBUG"


def test_path_comes_from_the_environment(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv(CONFIG_ENV_VAR, str(write(tmp_path, MINIMAL)))
    assert load_settings().db_host == "db.example.internal"


def test_missing_file(tmp_path: Path) -> None:
    with pytest.raises(ConfigError, match="not found"):
        load_settings(tmp_path / "nope.ini")


def test_missing_key(tmp_path: Path) -> None:
    with pytest.raises(ConfigError, match="password"):
        load_settings(write(tmp_path, MINIMAL.replace("password = p%ss#word\n", "")))


def test_invalid_port(tmp_path: Path) -> None:
    with pytest.raises(ConfigError, match="invalid"):
        load_settings(write(tmp_path, MINIMAL + "port = many\n"))
