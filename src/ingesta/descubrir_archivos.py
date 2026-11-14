from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path

# nombre_ddmmaaaa.ext
PATRON_GENERAL = re.compile(r"^(?P<nombre>.+)_(?P<fecha>\d{8})\.(?P<ext>csv|xlsx|txt)$", re.IGNORECASE)


@dataclass(frozen=True)
class ArchivoDetectado:
    ruta: Path
    nombre_archivo: str
    tamano_bytes: int
    hash_sha256: str
    cod_fuente: str | None       # None si no se reconoce
    fecha_corte: date | None
    motivo: str | None = None    # por qué no se reconoce


def fecha_desde_texto(ddmmaaaa: str) -> date:
    """'01112026' -> date(2026, 11, 1). ValueError si no es una fecha válida."""
    if not re.fullmatch(r"\d{8}", ddmmaaaa):
        raise ValueError(f"se esperaba ddmmaaaa: {ddmmaaaa!r}")
    return datetime.strptime(ddmmaaaa, "%d%m%Y").date()


def identificar(nombre: str, configs: list[dict]) -> tuple[str | None, date | None, str | None]:
    """Devuelve (cod_fuente, fecha_corte, motivo). motivo es None si el archivo se reconoce."""
    m = PATRON_GENERAL.fullmatch(nombre)
    if not m:
        return None, None, "el nombre no sigue el patrón nombre_ddmmaaaa.(csv|xlsx|txt)"
    try:
        fecha = fecha_desde_texto(m["fecha"])
    except ValueError:
        return None, None, f"fecha inválida en el nombre: {m['fecha']}"
    for cfg in configs:
        if re.fullmatch(cfg["patron"], nombre):
            return cfg["cod_fuente"], fecha, None
    return None, fecha, "tipo de archivo sin configuración activa en ctl.fuente_config"


def calcular_hash(ruta: Path) -> str:
    h = hashlib.sha256()
    with open(ruta, "rb") as f:
        for bloque in iter(lambda: f.read(1 << 20), b""):
            h.update(bloque)
    return h.hexdigest()


def descubrir(carpeta: Path, configs: list[dict], fecha: date | None = None) -> list[ArchivoDetectado]:
    """Archivos de la carpeta ordenados por fecha de corte y nombre. Ignora ocultos (.gitkeep) y
    temporales de Office (~$...). Con fecha, solo devuelve los de esa fecha de corte y los que no
    tienen fecha en el nombre (no son de otro día, así que siempre se informan como no reconocidos)."""
    detectados = []
    for ruta in carpeta.iterdir():
        if not ruta.is_file() or ruta.name.startswith((".", "~$")):
            continue
        cod, f_corte, motivo = identificar(ruta.name, configs)
        if fecha and f_corte is not None and f_corte != fecha:
            continue
        detectados.append(ArchivoDetectado(ruta, ruta.name, ruta.stat().st_size, calcular_hash(ruta),
                                           cod, f_corte, motivo))
    return sorted(detectados, key=lambda a: (a.fecha_corte or date.min, a.nombre_archivo))
