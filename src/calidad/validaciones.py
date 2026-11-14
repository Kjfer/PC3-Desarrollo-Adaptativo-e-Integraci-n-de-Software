"""Reglas de calidad -> ctl.resultado_calidad.

Dos grupos:
- Reglas de archivos (aquí, en Python): necesitan el calendario y la carpeta.
    ARCHIVO_FALTANTE       (ALERTA) un día sin carga vigente de una fuente diaria
    ARCHIVO_VACIO          (ALERTA) cargado, pero con 0 filas
    ARCHIVO_CON_ERROR      (ERROR)  no se pudo cargar en esta corrida
    ARCHIVO_NO_RECONOCIDO  (ALERTA) está en la carpeta y no corresponde a ninguna fuente
- Reglas de datos (sql/08_reglas_calidad.sql, ctl.sp_reglas_calidad): duplicados, llaves inválidas,
  valores no interpretables, huérfanos y consistencia. Se ejecutan en la base, cerca de los datos.

Cada regla deja una fila por fuente o tabla aunque no falle nada (filas_fallan = 0); los archivos
faltantes dejan además una fila por fecha.
"""
from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path

from sqlalchemy import text
from sqlalchemy.engine import Engine

from ingesta.descubrir_archivos import descubrir


@dataclass
class Hallazgo:
    regla: str
    tabla: str
    filas_fallan: int
    severidad: str          # ALERTA o ERROR
    detalle: str
    fecha_corte: date | None = None


@dataclass
class ResumenCalidad:
    reglas: int = 0
    con_hallazgos: int = 0
    errores: int = 0        # reglas de severidad ERROR con hallazgos
    alertas: int = 0        # reglas de severidad ALERTA con hallazgos


# ---------------------------------------------------------------------------
# Lógica pura (se prueba sin base de datos)
# ---------------------------------------------------------------------------
def fechas_esperadas(desde: date, hasta: date, frecuencia: str = "DIARIA") -> list[date]:
    """DIARIA: todos los días; HABIL: lunes a viernes."""
    dias = [desde + timedelta(days=i) for i in range((hasta - desde).days + 1)]
    if frecuencia.upper() == "HABIL":
        dias = [d for d in dias if d.weekday() < 5]
    return dias


def fechas_faltantes(cargadas: set[date], desde: date, hasta: date, frecuencia: str = "DIARIA") -> list[date]:
    return [d for d in fechas_esperadas(desde, hasta, frecuencia) if d not in cargadas]


def hallazgos_faltantes(cod_fuente: str, faltantes: list[date]) -> list[Hallazgo]:
    """Una fila por fecha faltante, o una fila en 0 si no falta ninguna."""
    if not faltantes:
        return [Hallazgo("ARCHIVO_FALTANTE", cod_fuente, 0, "ALERTA", "Sin días faltantes en el periodo.")]
    return [Hallazgo("ARCHIVO_FALTANTE", cod_fuente, 1, "ALERTA",
                     f"No hay carga vigente del {d:%d/%m/%Y} (no llegó o llegó con error).", d)
            for d in faltantes]


def resumir(hallazgos: list[Hallazgo]) -> ResumenCalidad:
    """Cuenta reglas (regla + tabla) y cuántas tuvieron hallazgos, por severidad."""
    por_regla: dict[tuple[str, str], Hallazgo] = {}
    fallan: dict[tuple[str, str], int] = {}
    for h in hallazgos:
        k = (h.regla, h.tabla)
        por_regla[k] = h
        fallan[k] = fallan.get(k, 0) + h.filas_fallan
    r = ResumenCalidad(reglas=len(por_regla))
    for k, h in por_regla.items():
        if fallan[k] > 0:
            r.con_hallazgos += 1
            if h.severidad == "ERROR":
                r.errores += 1
            else:
                r.alertas += 1
    return r


# ---------------------------------------------------------------------------
# Reglas de archivos
# ---------------------------------------------------------------------------
def _ejemplos(items: list[str], n: int = 5) -> str:
    return "; ".join(items[:n]) + (f" (+{len(items) - n} más)" if len(items) > n else "")


def reglas_archivos(eng: Engine, id_ejecucion: int, configs: list[dict], carpeta: Path,
                    fecha: date | None = None) -> list[Hallazgo]:
    hallazgos: list[Hallazgo] = []
    with eng.connect() as cn:
        cargas = cn.execute(text(
            "SELECT cod_fuente, fecha_corte, nombre_archivo, filas FROM ctl.archivo_cargado "
            "WHERE estado = 'CARGADO'")).all()
        errores = cn.execute(text(
            "SELECT nombre_archivo, mensaje FROM ctl.archivo_cargado "
            "WHERE id_ejecucion = :id AND estado = 'ERROR' ORDER BY nombre_archivo"), {"id": id_ejecucion}).all()

    # Periodo a revisar: la fecha pedida, o desde el primer hasta el último día con algún archivo
    fechas = [c.fecha_corte for c in cargas]
    desde, hasta = (fecha, fecha) if fecha else ((min(fechas), max(fechas)) if fechas else (None, None))

    for cfg in configs:
        cod = cfg["cod_fuente"]
        propias = [c for c in cargas if c.cod_fuente == cod]
        if desde and cfg.get("frecuencia") in ("DIARIA", "HABIL"):
            faltan = fechas_faltantes({c.fecha_corte for c in propias}, desde, hasta, cfg["frecuencia"])
            hallazgos += hallazgos_faltantes(cod, faltan)
        vacios = sorted(c.nombre_archivo for c in propias
                        if c.filas == 0 and (fecha is None or c.fecha_corte == fecha))
        hallazgos.append(Hallazgo("ARCHIVO_VACIO", cod, len(vacios), "ALERTA",
                                  "Archivos cargados con 0 filas (solo encabezado)."
                                  + (f" Ej.: {_ejemplos(vacios)}" if vacios else ""), fecha))

    hallazgos.append(Hallazgo(
        "ARCHIVO_CON_ERROR", "ctl.archivo_cargado", len(errores), "ERROR",
        "Archivos que no se pudieron cargar en esta corrida; raw no cambió para esa fecha."
        + (f" Ej.: {_ejemplos([f'{e.nombre_archivo}: {e.mensaje}' for e in errores], 3)}" if errores else ""), fecha))

    no_reconocidos = sorted(f"{a.nombre_archivo} ({a.motivo})" for a in descubrir(carpeta, configs, fecha)
                            if a.cod_fuente is None)
    hallazgos.append(Hallazgo(
        "ARCHIVO_NO_RECONOCIDO", str(carpeta.name), len(no_reconocidos), "ALERTA",
        "Archivos en la carpeta que no corresponden a ninguna fuente configurada."
        + (f" Ej.: {_ejemplos(no_reconocidos)}" if no_reconocidos else ""), fecha))
    return hallazgos


# ---------------------------------------------------------------------------
# Evaluación completa
# ---------------------------------------------------------------------------
def guardar(eng: Engine, id_ejecucion: int, hallazgos: list[Hallazgo]) -> None:
    with eng.begin() as cn:
        cn.execute(text(
            "INSERT INTO ctl.resultado_calidad (id_ejecucion, regla, tabla, fecha_corte, filas_fallan, severidad, detalle) "
            "VALUES (:id, :regla, :tabla, :fecha, :filas, :sev, :detalle)"),
            [{"id": id_ejecucion, "regla": h.regla, "tabla": h.tabla, "fecha": h.fecha_corte,
              "filas": h.filas_fallan, "sev": h.severidad, "detalle": h.detalle[:2000]} for h in hallazgos])


def leer_resultados(eng: Engine, id_ejecucion: int) -> list[Hallazgo]:
    with eng.connect() as cn:
        filas = cn.execute(text(
            "SELECT regla, tabla, filas_fallan, severidad, detalle, fecha_corte FROM ctl.resultado_calidad "
            "WHERE id_ejecucion = :id ORDER BY CASE severidad WHEN 'ERROR' THEN 0 ELSE 1 END, regla, tabla, fecha_corte"),
            {"id": id_ejecucion}).all()
    return [Hallazgo(f.regla, f.tabla, f.filas_fallan, f.severidad, f.detalle, f.fecha_corte) for f in filas]


def evaluar(eng: Engine, id_ejecucion: int, configs: list[dict], carpeta: Path,
            fecha: date | None = None) -> list[Hallazgo]:
    """Ejecuta las reglas de archivos (Python) y de datos (SQL); todo queda en ctl.resultado_calidad."""
    guardar(eng, id_ejecucion, reglas_archivos(eng, id_ejecucion, configs, carpeta, fecha))
    with eng.connect() as cn:
        cn = cn.execution_options(isolation_level="AUTOCOMMIT")
        cn.exec_driver_sql("EXEC ctl.sp_reglas_calidad @id_ejecucion = ?, @fecha_corte = ?", (id_ejecucion, fecha))
    return leer_resultados(eng, id_ejecucion)


def formatear_reporte(hallazgos: list[Hallazgo]) -> str:
    r = resumir(hallazgos)
    lineas = [f"Calidad: {r.reglas} reglas evaluadas, {r.reglas - r.con_hallazgos} sin hallazgos, "
              f"{r.errores} con errores, {r.alertas} con alertas"]
    for h in hallazgos:
        if h.filas_fallan:
            fecha = f" {h.fecha_corte:%d/%m/%Y}" if h.fecha_corte and h.regla == "ARCHIVO_FALTANTE" else ""
            lineas.append(f"  [{h.severidad}] {h.regla} {h.tabla}{fecha}: {h.filas_fallan} | {h.detalle[:160]}")
    return "\n".join(lineas)
