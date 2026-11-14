from __future__ import annotations

from datetime import datetime

import pandas as pd
from sqlalchemy import text
from sqlalchemy.engine import Engine

from control.auditoria import Auditoria
from db import con_reintentos, motor


def extraer_tabla(destino: Engine, origen: Engine, cfg: dict, id_ejecucion: int) -> tuple[int, object]:
    """Devuelve (filas extraídas, marca de agua usada)."""
    consulta, params, marca = f"SELECT * FROM {cfg['tabla_origen']}", {}, None
    if cfg["modo_carga"] == "INCREMENTAL":
        col = cfg["columna_marca_agua"]
        with destino.connect() as cn:
            marca = cn.execute(text(f"SELECT MAX({col}) FROM {cfg['tabla_destino']}")).scalar()
        if marca is not None:
            consulta += f" WHERE {col} > :marca"
            params["marca"] = marca

    with origen.connect() as cn:
        df = pd.read_sql(text(consulta), cn, params=params, coerce_float=False)
    df.insert(0, "id_ejecucion", id_ejecucion)
    df.insert(1, "fecha_carga", datetime.now().replace(microsecond=0))

    esquema, tabla = cfg["tabla_destino"].split(".", 1)
    with destino.begin() as cn:
        if cfg["modo_carga"] == "COMPLETA":
            cn.execute(text(f"TRUNCATE TABLE {cfg['tabla_destino']}"))
        if len(df):
            df.to_sql(tabla, cn, schema=esquema, if_exists="append", index=False, chunksize=1000)
    return len(df), marca


def extraer_tablas(destino: Engine, aud: Auditoria, configs: list[dict],
                   intentos: int = 1, espera: float = 0) -> int:
    """Extrae cada tabla configurada; un fallo en una tabla queda en ctl.log_paso y no detiene las demás.
    Cada extracción es una transacción, así que se puede reintentar ante fallas pasajeras."""
    motores: dict[str, Engine] = {}
    total = 0
    for cfg in configs:
        with aud.paso("EXTRACCION_BD", cfg["cod_fuente"]) as p:
            origen = motores.setdefault(cfg["base_origen"], motor(cfg["base_origen"]))
            (p.filas, marca), usados = con_reintentos(
                lambda: extraer_tabla(destino, origen, cfg, aud.id_ejecucion), intentos, espera)
            p.mensaje = (f"{cfg['modo_carga']}" +
                         (f" desde {cfg['columna_marca_agua']} > {marca}" if marca is not None else "") +
                         (f" (OK en el intento {usados})" if usados > 1 else ""))
            total += p.filas
    return total
