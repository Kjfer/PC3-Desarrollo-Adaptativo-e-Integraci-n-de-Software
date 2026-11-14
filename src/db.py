"""Conexión a SQL Server y ejecución de scripts .sql con separadores GO."""
from __future__ import annotations

import re
import time
import urllib.parse
from pathlib import Path
from typing import Callable, TypeVar

import pyodbc
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine

from config import env

_SEPARADOR_GO = re.compile(r"^\s*GO\s*;?\s*$", re.IGNORECASE | re.MULTILINE)


def cadena_odbc(base: str = "master") -> str:
    partes = [
        f"DRIVER={{{env('SQL_DRIVER', 'ODBC Driver 18 for SQL Server')}}}",
        f"SERVER={env('SQL_SERVER', 'localhost')}",
        f"DATABASE={base}",
    ]
    if env("SQL_TRUSTED_CONNECTION", "yes").lower() in ("yes", "true", "1"):
        partes.append("Trusted_Connection=yes")
    else:
        partes += [f"UID={env('SQL_USER')}", f"PWD={env('SQL_PASSWORD')}"]
    if env("SQL_TRUST_SERVER_CERTIFICATE", "yes").lower() in ("yes", "true", "1"):
        partes.append("TrustServerCertificate=yes")
    return ";".join(partes)


def conectar(base: str = "master", autocommit: bool = False) -> pyodbc.Connection:
    return pyodbc.connect(cadena_odbc(base), autocommit=autocommit)


def motor(base: str) -> Engine:
    """Engine de SQLAlchemy (para pandas.to_sql / read_sql) con inserción masiva."""
    url = "mssql+pyodbc:///?odbc_connect=" + urllib.parse.quote_plus(cadena_odbc(base))
    return create_engine(url, fast_executemany=True)


# SQLSTATE de fallas pasajeras: conexión (08001, 08S01), deadlock (40001), tiempo de espera (HYT00, HYT01)
SQLSTATE_TRANSITORIOS = {"08001", "08S01", "40001", "HYT00", "HYT01"}
T = TypeVar("T")


def es_transitorio(error: BaseException) -> bool:
    """True si el error es pasajero y vale la pena reintentar (pyodbc directo o envuelto por SQLAlchemy)."""
    orig = getattr(error, "orig", None) or error
    args = getattr(orig, "args", ())
    return bool(args) and isinstance(args[0], str) and args[0] in SQLSTATE_TRANSITORIOS


def con_reintentos(fn: Callable[[], T], intentos: int = 3, espera: float = 5.0,
                   dormir: Callable[[float], None] = time.sleep) -> tuple[T, int]:
    """Ejecuta fn y la reintenta solo ante errores pasajeros, esperando espera × n.º de intento.
    Devuelve (resultado, intentos usados). Un error de datos o de lógica se propaga de inmediato.
    Úsese solo con operaciones idempotentes (los procedimientos y extracciones lo son)."""
    for intento in range(1, intentos + 1):
        try:
            return fn(), intento
        except Exception as e:
            if intento == intentos or not es_transitorio(e):
                raise
            dormir(espera * intento)
    raise AssertionError("inalcanzable")


def ejecutar_proc(eng: Engine, proc: str) -> int:
    """Ejecuta un procedimiento que maneja su propia transacción y devuelve SELECT @filas AS filas."""
    with eng.connect() as cn:
        cn = cn.execution_options(isolation_level="AUTOCOMMIT")
        return cn.exec_driver_sql(f"EXEC {proc}").scalar() or 0


def _es_solo_comentario(lote: str) -> bool:
    return all(not l.strip() or l.strip().startswith("--") for l in lote.splitlines())


def ejecutar_script(ruta: Path) -> int:
    """Ejecuta un script T-SQL lote por lote (separados por GO). Devuelve el número de lotes."""
    texto = ruta.read_text(encoding="utf-8-sig")
    lotes = [l for l in _SEPARADOR_GO.split(texto) if l.strip() and not _es_solo_comentario(l)]
    with conectar("master", autocommit=True) as cn:
        cur = cn.cursor()
        for i, lote in enumerate(lotes, 1):
            try:
                cur.execute(lote)
                while cur.nextset():
                    pass
            except pyodbc.Error as e:
                inicio = next(l.strip() for l in lote.splitlines() if l.strip() and not l.strip().startswith("--"))
                raise RuntimeError(f"{ruta.name}, lote {i} ({inicio[:80]}): {e}") from e
    return len(lotes)
