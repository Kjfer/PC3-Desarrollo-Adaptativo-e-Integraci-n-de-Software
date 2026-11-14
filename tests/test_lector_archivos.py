from datetime import datetime

import pytest
from openpyxl import Workbook

from ingesta.lector_archivos import ErrorLectura, leer_archivo

CFG_CSV = {"formato": "csv", "separador": ";", "encoding": "utf-8", "columnas_esperadas": "id,texto,fecha"}
CFG_XLSX = {"formato": "xlsx", "hoja": "Rating", "texto_encabezado": "cod_cliente",
            "columnas_esperadas": "cod_cliente,rating,fecha_rating"}


def _excel(ruta, filas_titulo):
    wb = Workbook()
    ws = wb.active
    ws.title = "Rating"
    for t in filas_titulo:
        ws.append(t)
    ws.append(["cod_cliente", "rating", "fecha_rating"])
    ws.append([12345, "BBB", datetime(2026, 10, 3)])
    ws.append([])
    ws.append([987, "A", datetime(2026, 9, 1)])
    wb.save(ruta)


def test_csv_se_lee_como_texto_sin_corregir(tmp_path):
    f = tmp_path / "x.csv"
    f.write_text('id;texto;fecha\n007;"con ; adentro";2026-11-01\n008;;01/11/2026\n', encoding="utf-8")
    df = leer_archivo(f, CFG_CSV)
    assert df.to_dict("records") == [
        {"id": "007", "texto": "con ; adentro", "fecha": "2026-11-01"},
        {"id": "008", "texto": "", "fecha": "01/11/2026"},
    ]


def test_csv_solo_encabezado_da_cero_filas(tmp_path):
    f = tmp_path / "x.csv"
    f.write_text("id;texto;fecha\n", encoding="utf-8")
    assert len(leer_archivo(f, CFG_CSV)) == 0


def test_csv_vacio_es_error(tmp_path):
    f = tmp_path / "x.csv"
    f.write_text("")
    with pytest.raises(ErrorLectura, match="vacío"):
        leer_archivo(f, CFG_CSV)


def test_columnas_distintas_es_error(tmp_path):
    f = tmp_path / "x.csv"
    f.write_text("id;texto;otra\n1;a;b\n", encoding="utf-8")
    with pytest.raises(ErrorLectura, match=r"faltan \['fecha'\], sobran \['otra'\]"):
        leer_archivo(f, CFG_CSV)


@pytest.mark.parametrize("titulos", [
    [["REPORTE"], ["Fecha de corte: 01/11/2026"], []],
    [["REPORTE"], ["Fecha de corte: 01/11/2026"], ["Fuente: modelo interno"], []],
])
def test_excel_busca_el_encabezado(tmp_path, titulos):
    f = tmp_path / "r.xlsx"
    _excel(f, titulos)
    df = leer_archivo(f, CFG_XLSX)
    # cod_cliente queda como vino (número sin ceros); la fila vacía se ignora
    assert df.to_dict("records") == [
        {"cod_cliente": "12345", "rating": "BBB", "fecha_rating": "2026-10-03"},
        {"cod_cliente": "987", "rating": "A", "fecha_rating": "2026-09-01"},
    ]


def test_excel_sin_la_hoja_es_error(tmp_path):
    f = tmp_path / "r.xlsx"
    _excel(f, [])
    with pytest.raises(ErrorLectura, match="no existe la hoja"):
        leer_archivo(f, {**CFG_XLSX, "hoja": "Otra"})
