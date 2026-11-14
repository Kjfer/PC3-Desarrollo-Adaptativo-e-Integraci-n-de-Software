from datetime import date

import pytest

from calidad.validaciones import Hallazgo, fechas_esperadas, fechas_faltantes, hallazgos_faltantes, resumir
from db import con_reintentos, es_transitorio


# ---------------------------------------------------------------------------
# Archivos faltantes
# ---------------------------------------------------------------------------
def test_diaria_incluye_fines_de_semana():
    assert len(fechas_esperadas(date(2026, 11, 1), date(2026, 11, 7))) == 7


def test_habil_excluye_sabado_y_domingo():
    # 01/11/2026 es domingo; 07/11/2026 es sábado
    assert fechas_esperadas(date(2026, 11, 1), date(2026, 11, 7), "HABIL") == [
        date(2026, 11, d) for d in (2, 3, 4, 5, 6)]


def test_detecta_el_dia_faltante():
    cargadas = {date(2026, 10, d) for d in range(20, 31) if d != 25}
    assert fechas_faltantes(cargadas, date(2026, 10, 20), date(2026, 10, 30)) == [date(2026, 10, 25)]


def test_sin_faltantes_deja_una_fila_en_cero():
    [h] = hallazgos_faltantes("renovacion_lineas", [])
    assert (h.regla, h.filas_fallan, h.fecha_corte) == ("ARCHIVO_FALTANTE", 0, None)


def test_una_fila_por_fecha_faltante():
    hs = hallazgos_faltantes("renovacion_lineas", [date(2026, 10, 25), date(2026, 10, 26)])
    assert [h.fecha_corte for h in hs] == [date(2026, 10, 25), date(2026, 10, 26)]
    assert all(h.filas_fallan == 1 for h in hs)


def test_resumen_cuenta_reglas_no_filas():
    hs = [Hallazgo("ARCHIVO_FALTANTE", "renov", 1, "ALERTA", "", date(2026, 10, 25)),
          Hallazgo("ARCHIVO_FALTANTE", "renov", 1, "ALERTA", "", date(2026, 10, 26)),
          Hallazgo("ARCHIVO_FALTANTE", "rating", 0, "ALERTA", ""),
          Hallazgo("LLAVE_INVALIDA", "raw.x", 3, "ERROR", "")]
    r = resumir(hs)
    assert (r.reglas, r.con_hallazgos, r.errores, r.alertas) == (3, 2, 1, 1)


# ---------------------------------------------------------------------------
# Reintentos
# ---------------------------------------------------------------------------
class ErrorOdbc(Exception):
    """Imita pyodbc.Error: args[0] es el SQLSTATE."""


class ErrorEnvuelto(Exception):
    """Imita sqlalchemy.exc.DBAPIError: el error de pyodbc va en .orig."""
    def __init__(self, orig):
        super().__init__(str(orig))
        self.orig = orig


@pytest.mark.parametrize("error, esperado", [
    (ErrorOdbc("08S01", "enlace de comunicación"), True),
    (ErrorEnvuelto(ErrorOdbc("40001", "deadlock")), True),
    (ErrorOdbc("42S02", "objeto no existe"), False),
    (ValueError("dato malo"), False),
])
def test_es_transitorio(error, esperado):
    assert es_transitorio(error) is esperado


def test_reintenta_fallas_pasajeras_y_luego_funciona():
    llamadas, esperas = [], []

    def fn():
        llamadas.append(1)
        if len(llamadas) < 3:
            raise ErrorEnvuelto(ErrorOdbc("HYT00", "timeout"))
        return "ok"

    assert con_reintentos(fn, intentos=3, espera=2, dormir=esperas.append) == ("ok", 3)
    assert esperas == [2, 4]


def test_no_reintenta_errores_de_datos():
    llamadas = []

    def fn():
        llamadas.append(1)
        raise ErrorOdbc("23000", "violación de llave")

    with pytest.raises(ErrorOdbc):
        con_reintentos(fn, intentos=3, espera=0, dormir=lambda s: None)
    assert len(llamadas) == 1


def test_agota_los_intentos_y_propaga_el_error():
    def fn():
        raise ErrorOdbc("08S01", "sin conexión")

    with pytest.raises(ErrorOdbc):
        con_reintentos(fn, intentos=2, espera=0, dormir=lambda s: None)
