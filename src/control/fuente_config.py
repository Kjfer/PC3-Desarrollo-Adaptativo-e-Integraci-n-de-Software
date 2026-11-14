"""Sincroniza config/fuentes.yaml con ctl.fuente_config y devuelve la configuración activa.

El YAML es la fuente editable; ctl.fuente_config es lo que el pipeline usa en ejecución y lo que
queda consultable en la base (qué se cargó, con qué reglas).
"""
from __future__ import annotations

import re

import pandas as pd
from sqlalchemy import text
from sqlalchemy.engine import Engine

from config import fuentes


def filas_config(cfg_yaml: dict, bases: dict[str, str]) -> list[dict]:
    """Convierte fuentes.yaml a filas de ctl.fuente_config (sin tocar la base)."""
    filas = []
    for a in cfg_yaml.get("archivos") or []:
        formato = a["formato"].lower()
        filas.append({
            "cod_fuente": a["cod_fuente"], "tipo_fuente": "ARCHIVO", "descripcion": a.get("descripcion"),
            "tabla_destino": a["tabla_destino"],
            "patron": a.get("patron") or rf"^{re.escape(a['cod_fuente'])}_(?P<fecha>\d{{8}})\.{formato}$",
            "formato": formato, "separador": a.get("separador"),
            "encoding": None if formato == "xlsx" else a.get("encoding", "utf-8"),
            "hoja": a.get("hoja"), "texto_encabezado": a.get("texto_encabezado"),
            "columnas_esperadas": ",".join(a["columnas_esperadas"]),
            "frecuencia": a.get("frecuencia", "DIARIA"), "activo": bool(a.get("activo", True)),
        })
    for b in cfg_yaml.get("bases") or []:
        if b["modo_carga"] == "INCREMENTAL" and not b.get("columna_marca_agua"):
            raise ValueError(f"{b['cod_fuente']}: modo INCREMENTAL requiere columna_marca_agua")
        filas.append({
            "cod_fuente": b["cod_fuente"], "tipo_fuente": "BD", "descripcion": b.get("descripcion"),
            "tabla_destino": b["tabla_destino"], "base_origen": bases[b["origen"]],
            "tabla_origen": b["tabla_origen"], "modo_carga": b["modo_carga"],
            "columna_marca_agua": b.get("columna_marca_agua"), "activo": bool(b.get("activo", True)),
        })
    codigos = [f["cod_fuente"] for f in filas]
    if len(codigos) != len(set(codigos)):
        raise ValueError("cod_fuente repetido en config/fuentes.yaml")
    return filas


def sincronizar(eng: Engine, bases: dict[str, str]) -> list[dict]:
    df = pd.DataFrame(filas_config(fuentes(), bases))
    with eng.begin() as cn:
        cn.execute(text("DELETE FROM ctl.fuente_config"))
        df.to_sql("fuente_config", cn, schema="ctl", if_exists="append", index=False)
    activas = pd.read_sql("SELECT * FROM ctl.fuente_config WHERE activo = 1 ORDER BY cod_fuente", eng)
    return activas.astype(object).where(activas.notna(), None).to_dict("records")
