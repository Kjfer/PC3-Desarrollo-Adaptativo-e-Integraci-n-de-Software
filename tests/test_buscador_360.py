from datetime import date

import pandas as pd
import pytest

from buscador_360 import consultas_a_fecha, fmt_fecha, fmt_monto, interpretar_busqueda


# ---------------------------------------------------------------------------
# Interpretación del texto de búsqueda
# ---------------------------------------------------------------------------
def test_texto_vacio_no_filtra():
    assert interpretar_busqueda("Cliente", "   ") is None


def test_propuesta_por_numero():
    f = interpretar_busqueda("Propuesta", " 260074 ")
    assert (f.where, f.params) == ("id_propuesta = :v", {"v": 260074})


@pytest.mark.parametrize("texto", ["26007a", "1234567890"])
def test_propuesta_invalida(texto):
    with pytest.raises(ValueError):
        interpretar_busqueda("Propuesta", texto)


def test_cliente_recupera_ceros_que_borra_excel():
    f = interpretar_busqueda("Cliente", "48819")
    assert (f.where, f.params) == ("cod_cliente = :v", {"v": "00048819"})


def test_cliente_por_ruc():
    f = interpretar_busqueda("Cliente", "20500978820")
    assert (f.where, f.params) == ("ruc = :v", {"v": "20500978820"})


def test_cliente_con_9_digitos_es_invalido():
    with pytest.raises(ValueError):
        interpretar_busqueda("Cliente", "123456789")


def test_cliente_por_razon_social_escapa_comodines():
    f = interpretar_busqueda("Cliente", "Sol_100%")
    assert f.where == "razon_social LIKE :v"
    assert f.params == {"v": "%Sol[_]100[%]%"}


@pytest.mark.parametrize("texto", ["GE0007", "ge7", "GE 07"])
def test_grupo_por_codigo(texto):
    f = interpretar_busqueda("Grupo económico", texto)
    assert (f.where, f.params) == ("cod_grupo_economico = :v", {"v": "GE0007"})


def test_grupo_por_nombre():
    f = interpretar_busqueda("Grupo económico", "Cerro")
    assert (f.where, f.params) == ("nombre_grupo LIKE :v", {"v": "%Cerro%"})


# ---------------------------------------------------------------------------
# Formato
# ---------------------------------------------------------------------------
def test_formatos():
    assert fmt_monto(61104209.53, "USD") == "USD 61,104,209.53"
    assert fmt_monto(None) == "—"
    assert fmt_fecha(date(2026, 11, 4)) == "04/11/2026"
    assert fmt_fecha(None) == "—"


# ---------------------------------------------------------------------------
# Consultas a una fecha
# ---------------------------------------------------------------------------
def _consultas():
    return pd.DataFrame({
        "nro_consulta": [1, 2, 3],
        "fecha_pregunta": [date(2026, 10, 23), date(2026, 10, 23), date(2026, 10, 29)],
        "fecha_respuesta": [date(2026, 10, 24), date(2026, 10, 27), None],
        "respuesta": ["r1", "r2", None],
        "estado": ["RESPONDIDA", "RESPONDIDA", "PENDIENTE"],
        "dias_respuesta": [1, 4, None],
    })


def test_consultas_a_fecha_oculta_futuro():
    df = consultas_a_fecha(_consultas(), date(2026, 10, 25))
    assert list(df["nro_consulta"]) == [1, 2]                  # la 3 se preguntó después
    assert list(df["estado"]) == ["RESPONDIDA", "PENDIENTE"]   # la 2 se respondió después
    assert pd.isna(df.iloc[1]["respuesta"]) and pd.isna(df.iloc[1]["fecha_respuesta"])


def test_consultas_sin_fecha_no_cambian():
    df = _consultas()
    assert consultas_a_fecha(df, None) is df
