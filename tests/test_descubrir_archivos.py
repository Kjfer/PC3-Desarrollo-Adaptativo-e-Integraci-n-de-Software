from datetime import date

import pytest

from ingesta.descubrir_archivos import calcular_hash, descubrir, fecha_desde_texto, identificar

CONFIGS = [
    {"cod_fuente": "consultas_propuesta", "patron": r"^consultas_propuesta_(?P<fecha>\d{8})\.csv$"},
    {"cod_fuente": "rating_cliente", "patron": r"^rating_cliente_(?P<fecha>\d{8})\.xlsx$"},
]


def test_fecha_ddmmaaaa():
    assert fecha_desde_texto("01112026") == date(2026, 11, 1)


@pytest.mark.parametrize("texto", ["32012026", "01132026", "2026111", "abcdefgh"])
def test_fecha_invalida(texto):
    with pytest.raises(ValueError):
        fecha_desde_texto(texto)


def test_identifica_tipo_y_fecha():
    assert identificar("consultas_propuesta_25102026.csv", CONFIGS) == ("consultas_propuesta", date(2026, 10, 25), None)
    assert identificar("rating_cliente_01112026.xlsx", CONFIGS)[:2] == ("rating_cliente", date(2026, 11, 1))


@pytest.mark.parametrize("nombre, fragmento", [
    ("consultas_propuesta.csv", "patrón"),                # sin fecha
    ("consultas_propuesta_31022026.csv", "fecha inválida"),
    ("consultas_propuesta_01112026.docx", "patrón"),      # extensión no admitida
    ("reporte_nuevo_01112026.csv", "sin configuración"),  # tipo no configurado
    ("rating_cliente_01112026.csv", "sin configuración"), # formato distinto al configurado
])
def test_no_reconocidos(nombre, fragmento):
    cod, _, motivo = identificar(nombre, CONFIGS)
    assert cod is None and fragmento in motivo


def test_descubrir_ordena_filtra_e_ignora_ocultos(tmp_path):
    for nombre in ["consultas_propuesta_02112026.csv", "consultas_propuesta_01112026.csv",
                   "rating_cliente_01112026.xlsx", ".gitkeep", "~$rating_cliente_01112026.xlsx"]:
        (tmp_path / nombre).write_text(nombre)
    todos = descubrir(tmp_path, CONFIGS)
    assert [a.nombre_archivo for a in todos] == [
        "consultas_propuesta_01112026.csv", "rating_cliente_01112026.xlsx", "consultas_propuesta_02112026.csv"]
    solo = descubrir(tmp_path, CONFIGS, date(2026, 11, 2))
    assert [a.nombre_archivo for a in solo] == ["consultas_propuesta_02112026.csv"]


def test_con_fecha_igual_informa_archivos_sin_fecha(tmp_path):
    for nombre in ["consultas_propuesta_01112026.csv", "consultas_propuesta_02112026.csv",
                   "pendientes.txt", "reporte_nuevo_01112026.csv"]:
        (tmp_path / nombre).write_text(nombre)
    solo = descubrir(tmp_path, CONFIGS, date(2026, 11, 2))
    # el no reconocido sin fecha se incluye; el no reconocido de otro día, no
    assert [(a.nombre_archivo, a.cod_fuente) for a in solo] == [
        ("pendientes.txt", None), ("consultas_propuesta_02112026.csv", "consultas_propuesta")]


def test_hash_cambia_con_el_contenido(tmp_path):
    f = tmp_path / "a.csv"
    f.write_text("x")
    h1 = calcular_hash(f)
    assert h1 == calcular_hash(f)
    f.write_text("y")
    assert calcular_hash(f) != h1
