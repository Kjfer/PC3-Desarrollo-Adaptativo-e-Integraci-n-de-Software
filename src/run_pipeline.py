from __future__ import annotations

import argparse
import sys

from calidad.validaciones import evaluar, formatear_reporte, resumir
from config import ruta, settings
from control.auditoria import Auditoria
from control.fuente_config import sincronizar
from db import con_reintentos, ejecutar_proc, ejecutar_script, motor
from ingesta.descubrir_archivos import fecha_desde_texto
from ingesta.extractor_bd import extraer_tablas
from ingesta.lector_archivos import ingestar_archivos

# Procedimientos en orden (sql/04 y sql/06). Cada uno maneja su transacción y es idempotente.
PROCS_STG = ["stg.sp_bases", "stg.sp_consultas_propuesta", "stg.sp_rating_cliente", "stg.sp_renovacion_lineas"]
PROCS_DWH = ["dwh.sp_dimensiones", "dwh.sp_fact_propuesta", "dwh.sp_fact_consulta",
             "dwh.sp_fact_rating_cliente", "dwh.sp_fact_riesgo"]


def ejecutar_procs(eng, aud: Auditoria, paso: str, procs: list[str], intentos: int, espera: float) -> bool:
    """Ejecuta los procedimientos en orden, cada uno auditado en ctl.log_paso. True si todos terminaron OK."""
    errores_antes = aud.errores
    for proc in procs:
        with aud.paso(paso, proc) as p:
            p.filas, usados = con_reintentos(lambda: ejecutar_proc(eng, proc), intentos, espera)
            if usados > 1:
                p.mensaje = f"OK en el intento {usados}"
        print(f"  {proc}: {p.estado} ({p.filas if p.filas is not None else '-'} filas)"
              + (f" - {p.mensaje}" if p.mensaje else ""))
    return aud.errores == errores_antes


def inicializar() -> None:
    for s in sorted(ruta("sql").glob("[0-9][0-9]_*.sql")):
        print(f"OK  {s.name} ({ejecutar_script(s)} lotes)")


def ejecutar(fecha_txt: str | None, forzar: bool) -> int:
    fecha = fecha_desde_texto(fecha_txt) if fecha_txt else None
    forzar = forzar or fecha is not None          # reprocesar una fecha = recargar sus archivos
    cfg = settings()
    orq = cfg.get("orquestacion", {})
    intentos, espera = 1 + int(orq.get("reintentos", 0)), float(orq.get("espera_segundos", 0))
    carpeta = ruta("ruta_compartida")

    eng = motor(cfg["bases"]["integrado"])
    aud = Auditoria(eng)
    modo = "REPROCESO" if fecha else "DIARIO"
    aud.iniciar(modo, f"fecha={fecha_txt or '-'} forzar={forzar}")
    print(f"Ejecución {aud.id_ejecucion} ({modo}{' ' + f'{fecha:%d/%m/%Y}' if fecha else ''})")
    resumen_calidad = ""
    try:
        configs = sincronizar(eng, cfg["bases"])
        cfg_archivos = [c for c in configs if c["tipo_fuente"] == "ARCHIVO"]
        cfg_bd = [c for c in configs if c["tipo_fuente"] == "BD"]

        # 1. Ingesta -> raw
        with aud.paso("INGESTA_ARCHIVOS", str(carpeta)) as p:
            r = ingestar_archivos(eng, aud, cfg_archivos, carpeta, fecha, forzar)
            p.filas = r.filas
            p.mensaje = (f"cargados={r.cargados} recargados={r.recargados} omitidos={r.omitidos} "
                         f"errores={r.errores} no_reconocidos={r.no_reconocidos}")
            if r.errores:
                p.estado = "CON ERRORES"
        print(f"Archivos: {p.mensaje}, filas={r.filas}")

        filas_bd = extraer_tablas(eng, aud, cfg_bd, intentos, espera)
        print(f"Bases: {len(cfg_bd)} tablas, {filas_bd} filas")

        # 2. stg -> 3. dwh (no se carga dwh desde un stg incompleto; la próxima corrida lo reintenta)
        print("Staging:")
        if ejecutar_procs(eng, aud, "STG", PROCS_STG, intentos, espera):
            print("Integrado:")
            ejecutar_procs(eng, aud, "DWH", PROCS_DWH, intentos, espera)
        else:
            with aud.paso("DWH", "omitido") as p:
                p.estado, p.mensaje = "ERROR", "No se cargó dwh porque stg terminó con errores"
            aud.errores += 1
            print("Integrado: omitido (stg con errores)")

        # 4. Calidad (se evalúa siempre, también si hubo errores, para dejarlos reportados)
        with aud.paso("CALIDAD", "reglas") as p:
            hallazgos = evaluar(eng, aud.id_ejecucion, cfg_archivos, carpeta, fecha)
            rc = resumir(hallazgos)
            p.filas = rc.con_hallazgos
            p.mensaje = resumen_calidad = (f"calidad: {rc.reglas} reglas, {rc.errores} con errores, "
                                           f"{rc.alertas} con alertas")
            print(formatear_reporte(hallazgos))
    except Exception as e:
        aud.finalizar("FALLIDA", f"{type(e).__name__}: {e}")
        raise
    estado = aud.finalizar(mensaje=resumen_calidad or None)
    print(f"Estado: {estado}")
    if estado != "OK":
        print(f"Detalle: ctl.log_paso y ctl.archivo_cargado (WHERE id_ejecucion = {aud.id_ejecucion})")
    print(f"Reporte de calidad: SELECT * FROM ctl.vw_calidad_ultima_ejecucion")
    return 0 if estado == "OK" else 1


def main() -> None:
    # La consola de Windows usa cp1252/cp850 al redirigir la salida (pipe, log); forzar UTF-8 conserva los acentos
    sys.stdout.reconfigure(encoding="utf-8")
    ap = argparse.ArgumentParser(description="Pipeline de integración ARC")
    ap.add_argument("--init", action="store_true", help="crea bases, esquemas, tablas y procedimientos")
    ap.add_argument("--fecha", help="reprocesar una fecha de corte ddmmaaaa (recarga sus archivos)")
    ap.add_argument("--forzar", action="store_true", help="recargar archivos aunque su hash no haya cambiado")
    args = ap.parse_args()

    if args.init:
        inicializar()
        return
    sys.exit(ejecutar(args.fecha, args.forzar))


if __name__ == "__main__":
    main()
