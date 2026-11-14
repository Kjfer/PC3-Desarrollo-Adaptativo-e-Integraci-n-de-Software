from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path

import pandas as pd
from openpyxl import load_workbook
from sqlalchemy import text
from sqlalchemy.engine import Connection, Engine

from control.auditoria import Auditoria
from ingesta.descubrir_archivos import ArchivoDetectado, descubrir


class ErrorLectura(Exception):
    """El archivo no se puede leer o no tiene la estructura esperada."""


# ---------------------------------------------------------------------------
# Lectura
# ---------------------------------------------------------------------------
def a_texto(v) -> str:
    """Valor de una celda de Excel como texto, sin inventar formato."""
    if v is None:
        return ""
    if isinstance(v, datetime):
        return v.date().isoformat() if v.time() == datetime.min.time() else v.isoformat(sep=" ")
    if isinstance(v, date):
        return v.isoformat()
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    return str(v)


def _leer_delimitado(ruta: Path, separador: str, encoding: str) -> pd.DataFrame:
    try:
        df = pd.read_csv(ruta, sep=separador, dtype=str, keep_default_na=False, encoding=encoding)
    except pd.errors.EmptyDataError:
        raise ErrorLectura("archivo vacío: no tiene ni encabezado") from None
    except (UnicodeDecodeError, pd.errors.ParserError) as e:
        raise ErrorLectura(f"no se pudo leer el archivo: {e}") from None
    df.columns = [str(c).lstrip("﻿").strip() for c in df.columns]
    return df


def _leer_excel(ruta: Path, hoja: str | None, texto_encabezado: str | None) -> pd.DataFrame:
    try:
        wb = load_workbook(ruta, read_only=True, data_only=True)
    except Exception as e:  # noqa: BLE001 - cualquier fallo de openpyxl es un archivo ilegible
        raise ErrorLectura(f"no se pudo abrir el Excel: {e}") from None
    try:
        if hoja and hoja not in wb.sheetnames:
            raise ErrorLectura(f"no existe la hoja '{hoja}' (hojas: {', '.join(wb.sheetnames)})")
        ws = wb[hoja] if hoja else wb.worksheets[0]
        filas = [[a_texto(v).strip() for v in fila] for fila in ws.iter_rows(values_only=True)]
    finally:
        wb.close()

    # Las filas de título varían: se busca la fila del encabezado en vez de saltar N filas
    objetivo = (texto_encabezado or "").strip().lower()
    i_enc = next((i for i, f in enumerate(filas)
                  if (objetivo and objetivo in (v.lower() for v in f)) or (not objetivo and any(f))), None)
    if i_enc is None:
        raise ErrorLectura(f"no se encontró la fila de encabezado ('{texto_encabezado}')")
    encabezado = filas[i_enc]
    indices = [j for j, v in enumerate(encabezado) if v]
    datos = [[f[j] if j < len(f) else "" for j in indices]
             for f in filas[i_enc + 1:] if any(f)]
    return pd.DataFrame(datos, columns=[encabezado[j] for j in indices], dtype=str)


def validar_columnas(df: pd.DataFrame, esperadas: list[str]) -> pd.DataFrame:
    """Exige exactamente las columnas esperadas (en cualquier orden) y las devuelve en ese orden."""
    faltan = [c for c in esperadas if c not in df.columns]
    sobran = [c for c in df.columns if c not in esperadas]
    if faltan or sobran:
        raise ErrorLectura(f"columnas distintas a las esperadas; faltan {faltan}, sobran {sobran}")
    return df[esperadas]


def leer_archivo(ruta: Path, cfg: dict) -> pd.DataFrame:
    formato = cfg["formato"]
    if formato in ("csv", "txt"):
        df = _leer_delimitado(ruta, cfg["separador"], cfg.get("encoding") or "utf-8")
    elif formato == "xlsx":
        df = _leer_excel(ruta, cfg.get("hoja"), cfg.get("texto_encabezado"))
    else:
        raise ErrorLectura(f"formato no soportado: {formato}")
    return validar_columnas(df, cfg["columnas_esperadas"].split(","))


# ---------------------------------------------------------------------------
# Carga a raw
# ---------------------------------------------------------------------------
def escribir_raw(cn: Connection, df: pd.DataFrame, tabla_destino: str, archivo: ArchivoDetectado,
                 id_archivo: int) -> None:
    esquema, tabla = tabla_destino.split(".", 1)
    salida = df.copy()
    salida.insert(0, "id_archivo", id_archivo)
    salida.insert(1, "archivo_origen", archivo.nombre_archivo)
    salida.insert(2, "fecha_corte", archivo.fecha_corte)
    salida.insert(3, "nro_fila", range(1, len(df) + 1))
    salida.insert(4, "fecha_carga", datetime.now().replace(microsecond=0))
    if len(salida):
        salida.to_sql(tabla, cn, schema=esquema, if_exists="append", index=False, chunksize=1000)


@dataclass
class ResumenIngesta:
    cargados: int = 0
    recargados: int = 0
    omitidos: int = 0
    errores: int = 0
    no_reconocidos: int = 0
    filas: int = 0


def ingestar_archivos(eng: Engine, aud: Auditoria, configs: list[dict], carpeta: Path,
                      fecha: date | None = None, forzar: bool = False) -> ResumenIngesta:
    """Carga a raw los archivos nuevos o modificados. Idempotente:
    - mismo hash que la carga vigente de ese tipo y fecha -> se omite (salvo forzar)
    - hash distinto -> se borra esa fecha de la tabla raw y se recarga; la carga anterior queda
      como REEMPLAZADO
    - error de lectura o de carga -> estado ERROR, raw no cambia (transacción revertida)
    """
    r = ResumenIngesta()
    por_codigo = {c["cod_fuente"]: c for c in configs}
    for a in descubrir(carpeta, configs, fecha):
        if a.cod_fuente is None:
            with eng.begin() as cn:
                if not aud.ya_registrado(cn, a.nombre_archivo, a.hash_sha256):
                    aud.registrar_archivo(cn, a, "NO_RECONOCIDO", mensaje=a.motivo)
            r.no_reconocidos += 1
            continue

        cfg = por_codigo[a.cod_fuente]
        with eng.connect() as cn:
            vigente = aud.hash_vigente(cn, a.cod_fuente, a.fecha_corte)
        if vigente == a.hash_sha256 and not forzar:
            r.omitidos += 1
            continue

        try:
            df = leer_archivo(a.ruta, cfg)
            with eng.begin() as cn:
                aud.reemplazar_vigente(cn, a.cod_fuente, a.fecha_corte)
                cn.execute(text(f"DELETE FROM {cfg['tabla_destino']} WHERE fecha_corte = :f"),
                           {"f": a.fecha_corte})
                mensaje = None if vigente is None else (
                    "Recarga forzada" if vigente == a.hash_sha256 else "Recarga: el archivo cambió")
                id_archivo = aud.registrar_archivo(cn, a, "CARGADO", filas=len(df), mensaje=mensaje)
                escribir_raw(cn, df, cfg["tabla_destino"], a, id_archivo)
        except Exception as e:  # noqa: BLE001 - se audita el archivo y se sigue con los demás
            with eng.begin() as cn:
                aud.registrar_archivo(cn, a, "ERROR", mensaje=f"{type(e).__name__}: {e}")
            aud.errores += 1
            r.errores += 1
            continue
        if vigente is None:
            r.cargados += 1
        else:
            r.recargados += 1
        r.filas += len(df)
    return r
