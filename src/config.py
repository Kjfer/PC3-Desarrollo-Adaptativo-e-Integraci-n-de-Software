"""Lectura de configuración: config/settings.yaml, config/fuentes.yaml y variables de .env."""
from __future__ import annotations

import os
from functools import lru_cache
from pathlib import Path

import yaml
from dotenv import load_dotenv

RAIZ = Path(__file__).resolve().parent.parent
load_dotenv(RAIZ / ".env")


@lru_cache(maxsize=1)
def settings() -> dict:
    with open(RAIZ / "config" / "settings.yaml", encoding="utf-8") as f:
        return yaml.safe_load(f)


def fuentes() -> dict:
    """config/fuentes.yaml (sin caché: se relee en cada corrida)."""
    with open(RAIZ / "config" / "fuentes.yaml", encoding="utf-8") as f:
        return yaml.safe_load(f)


def ruta(clave: str) -> Path:
    """Ruta absoluta de una entrada de settings.yaml > rutas."""
    return RAIZ / settings()["rutas"][clave]


def env(nombre: str, defecto: str = "") -> str:
    return os.getenv(nombre, defecto).strip()
