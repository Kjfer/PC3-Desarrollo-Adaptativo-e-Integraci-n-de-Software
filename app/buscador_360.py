from __future__ import annotations

import re
import sys
import time
from dataclasses import dataclass
from datetime import date
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
if str(RAIZ / "src") not in sys.path:
    sys.path.insert(0, str(RAIZ / "src"))

import pandas as pd  # noqa: E402
import streamlit as st  # noqa: E402
from sqlalchemy import text  # noqa: E402

from config import settings  # noqa: E402
from db import motor  # noqa: E402

TIPOS = ("Propuesta", "Cliente", "Grupo económico")
LARGO_COD_CLIENTE = 8  # stg.fn_cod_cliente: texto de 8 posiciones con ceros a la izquierda
LARGO_RUC = 11
MAX_RESULTADOS = 200


# ----------------------------------------------------------------------------------------------
# Lógica pura (probada en tests/test_buscador_360.py)
# ----------------------------------------------------------------------------------------------
@dataclass(frozen=True)
class Filtro:
    where: str        # condición sobre las columnas de fn_propuesta_360; los valores van en params
    params: dict
    descripcion: str


def _patron_like(texto: str) -> str:
    """Patrón LIKE que contiene el texto, con los comodines de T-SQL escapados."""
    return "%" + re.sub(r"([\[%_])", r"[\1]", texto) + "%"


def interpretar_busqueda(tipo: str, texto: str) -> Filtro | None:
    """Traduce lo que escribe el usuario a un filtro. None si no hay texto; ValueError si no es válido.

    - Propuesta: número exacto.
    - Cliente: 11 dígitos = RUC; hasta 8 dígitos = código (se completan los ceros que Excel borra);
      cualquier otro texto busca dentro de la razón social.
    - Grupo económico: GE + número = código (GE7 -> GE0007); otro texto busca dentro del nombre.
    """
    t = texto.strip()
    if not t:
        return None
    if tipo == "Propuesta":
        if not t.isdigit() or len(t) > 9:
            raise ValueError("El número de propuesta solo lleva dígitos, por ejemplo 260074.")
        return Filtro("id_propuesta = :v", {"v": int(t)}, f"propuesta {int(t)}")
    if tipo == "Cliente":
        if t.isdigit():
            if len(t) == LARGO_RUC:
                return Filtro("ruc = :v", {"v": t}, f"RUC {t}")
            if len(t) <= LARGO_COD_CLIENTE:
                cod = t.zfill(LARGO_COD_CLIENTE)
                return Filtro("cod_cliente = :v", {"v": cod}, f"cliente {cod}")
            raise ValueError(f"Un código de cliente tiene hasta {LARGO_COD_CLIENTE} dígitos y un RUC {LARGO_RUC}.")
        return Filtro("razon_social LIKE :v", {"v": _patron_like(t)}, f"razón social que contiene «{t}»")
    if tipo == "Grupo económico":
        m = re.fullmatch(r"GE\s*(\d{1,4})", t, re.IGNORECASE)
        if m:
            cod = "GE" + m.group(1).zfill(4)
            return Filtro("cod_grupo_economico = :v", {"v": cod}, f"grupo {cod}")
        return Filtro("nombre_grupo LIKE :v", {"v": _patron_like(t)}, f"grupo que contiene «{t}»")
    raise ValueError(f"Tipo de búsqueda desconocido: {tipo}")


def fmt_monto(valor, moneda: str = "PEN") -> str:
    if valor is None or pd.isna(valor):
        return "—"
    return f"{moneda} {float(valor):,.2f}"


def fmt_fecha(valor) -> str:
    if valor is None or pd.isna(valor):
        return "—"
    return pd.Timestamp(valor).strftime("%d/%m/%Y")


def fmt_valor(valor, sufijo: str = "") -> str:
    if valor is None or pd.isna(valor):
        return "—"
    return f"{valor}{sufijo}"


def consultas_a_fecha(df: pd.DataFrame, fecha_evaluacion) -> pd.DataFrame:
    """Consultas como se veían en la fecha de evaluación: solo preguntas hechas hasta ese día, y sin la
    respuesta si llegó después (igual que el conteo de pendientes de fn_propuesta_360)."""
    if fecha_evaluacion is None or pd.isna(fecha_evaluacion) or df.empty:
        return df
    f = pd.Timestamp(fecha_evaluacion)
    df = df[pd.to_datetime(df["fecha_pregunta"]) <= f].copy()
    tardia = pd.to_datetime(df["fecha_respuesta"]) > f
    df.loc[tardia, ["fecha_respuesta", "respuesta", "dias_respuesta"]] = None
    df.loc[tardia, "estado"] = "PENDIENTE"
    return df


# ----------------------------------------------------------------------------------------------
# Acceso a datos (solo lectura)
# ----------------------------------------------------------------------------------------------
@st.cache_resource
def _motor():
    return motor(settings()["bases"]["integrado"])


def leer(sql: str, **params) -> pd.DataFrame:
    with _motor().connect() as cn:
        return pd.read_sql(text(sql), cn, params=params)


COLUMNAS_LISTA = ("id_propuesta, fecha_ingreso, estado, tipo_propuesta, cod_cliente, razon_social, "
                  "nombre_grupo, nombre_banca, analista, moneda, monto_solicitado, rating, n_consultas_pendientes")


def buscar(filtro: Filtro | None, fecha: date | None) -> pd.DataFrame:
    if filtro is None:  # sin texto: las propuestas en evaluación, para empezar a navegar
        where, params = "estado = 'EN EVALUACION'", {}
    else:
        where, params = filtro.where, filtro.params
    return leer(f"SELECT TOP {MAX_RESULTADOS} {COLUMNAS_LISTA} FROM dwh.fn_propuesta_360(:fecha) "
                f"WHERE {where} ORDER BY fecha_ingreso DESC, id_propuesta DESC", fecha=fecha, **params)


def ficha_360(id_propuesta: int, fecha: date | None) -> dict:
    """Fila 360 y detalle de la propuesta. Devuelve también el tiempo total de consulta."""
    t0 = time.perf_counter()
    fila = leer("SELECT * FROM dwh.fn_propuesta_360(:fecha) WHERE id_propuesta = :id", fecha=fecha, id=id_propuesta)
    lineas = leer("SELECT id_linea, tipo_linea, moneda, monto, plazo_meses, fecha_vencimiento, renovacion, "
                  "fecha_corte_renovacion FROM dwh.vw_propuesta_lineas WHERE id_propuesta = :id ORDER BY id_linea",
                  id=id_propuesta)
    garantias = leer("SELECT id_garantia, tipo_garantia, moneda, valor_comercial, valor_realizacion, cobertura_pct "
                     "FROM dwh.vw_propuesta_garantias WHERE id_propuesta = :id ORDER BY id_garantia", id=id_propuesta)
    consultas = leer("SELECT ronda, nro_consulta, fecha_pregunta, pregunta, fecha_respuesta, respuesta, estado, "
                     "dias_respuesta, fecha_corte_primera, fecha_corte_ultima FROM dwh.vw_propuesta_consultas "
                     "WHERE id_propuesta = :id ORDER BY ronda, nro_consulta", id=id_propuesta)
    return {"fila": fila, "lineas": lineas, "garantias": garantias, "consultas": consultas,
            "ms": (time.perf_counter() - t0) * 1000}


@st.cache_data(ttl=60)
def estado_datos() -> dict:
    ult = leer("SELECT TOP 1 id_ejecucion, modo, fin, estado, mensaje FROM ctl.log_ejecucion "
               "WHERE fin IS NOT NULL ORDER BY id_ejecucion DESC")
    rng = leer("SELECT MIN(fecha_ingreso) AS desde, (SELECT MAX(fecha_corte) FROM dwh.fact_riesgo_cliente) AS hasta, "
               "(SELECT MIN(fecha_corte) FROM dwh.fact_rating_cliente) AS primer_rating, "
               "COUNT(*) AS propuestas, SUM(CASE WHEN fecha_resolucion IS NULL THEN 1 ELSE 0 END) AS en_evaluacion "
               "FROM dwh.fact_propuesta")
    return {"ultima": ult.iloc[0].to_dict() if not ult.empty else None, **rng.iloc[0].to_dict()}


# ----------------------------------------------------------------------------------------------
# Interfaz
# ----------------------------------------------------------------------------------------------
def barra_lateral(datos: dict) -> tuple[str, str, date | None]:
    st.sidebar.header("Búsqueda")
    tipo = st.sidebar.radio("Buscar por", TIPOS, horizontal=False)
    ayuda = {"Propuesta": "Número, p. ej. 260074",
             "Cliente": "Código (con o sin ceros), RUC o parte de la razón social",
             "Grupo económico": "Código (GE0007 o GE7) o parte del nombre"}[tipo]
    texto = st.sidebar.text_input("Texto", placeholder=ayuda, help=ayuda)

    fecha = None
    if st.sidebar.toggle("Estado a una fecha", help="Muestra cada propuesta como se veía ese día: estado, "
                         "consultas pendientes, rating y riesgos vigentes. Sin marcar: estado actual."):
        desde, hasta = pd.Timestamp(datos["desde"]).date(), pd.Timestamp(datos["hasta"]).date()
        fecha = st.sidebar.date_input("Fecha", value=hasta, min_value=desde, max_value=hasta, format="DD/MM/YYYY")

    st.sidebar.divider()
    st.sidebar.subheader("Datos")
    st.sidebar.caption(f"Periodo: {fmt_fecha(datos['desde'])} al {fmt_fecha(datos['hasta'])}")
    u = datos["ultima"]
    if u:
        icono = "✅" if u["estado"] == "OK" else "⚠️"
        st.sidebar.caption(f"{icono} Última corrida #{u['id_ejecucion']} ({u['modo']}): "
                           f"{pd.Timestamp(u['fin']):%d/%m/%Y %H:%M} · {u['estado']}")
        if u["mensaje"]:
            st.sidebar.caption(f"Calidad: {u['mensaje'].removeprefix('calidad: ')}")
    st.sidebar.caption("Proyecto académico · datos sintéticos")
    return tipo, texto, fecha


def ficha(titulo: str, pares: list[tuple[str, str]]) -> None:
    st.markdown(f"**{titulo}**")
    st.markdown("\n".join(f"- {k}: {v}" for k, v in pares))


def mostrar_ficha(d: dict, fecha: date | None, primer_rating) -> None:
    if d["fila"].empty:
        st.warning("La propuesta no existe a esa fecha (ingresó después).")
        return
    p = d["fila"].iloc[0]
    mon = p["moneda"]

    st.subheader(f"Propuesta {p['id_propuesta']} · {p['razon_social']}")
    st.caption(f"{p['tipo_propuesta']} · Banca {p['nombre_banca']} · "
               f"Analista: {p['analista'] if pd.notna(p['analista']) else 'sin asignar'} · "
               + (f"Estado al {fecha:%d/%m/%Y}" if fecha else "Estado actual")
               + f" · Vista 360 armada en {d['ms']:.0f} ms")

    if pd.isna(p["rating"]):
        sin_rating = ("Sin rating: la evaluación es anterior al primer archivo de rating"
                      if pd.notna(p["fecha_evaluacion"]) and pd.notna(primer_rating)
                      and pd.Timestamp(p["fecha_evaluacion"]) < pd.Timestamp(primer_rating)
                      else "Sin rating en los archivos")
    c = st.columns(5)
    c[0].metric("Estado", p["estado"])
    c[1].metric("Monto solicitado", fmt_monto(p["monto_solicitado"], mon))
    c[2].metric("Monto aprobado", fmt_monto(p["monto_aprobado"], mon))
    c[3].metric("Días en el área", fmt_valor(p["dias_en_area"]))
    c[4].metric("Rating", fmt_valor(p["rating"]),
                help=(f"{p['modelo_rating']} · foto del {fmt_fecha(p['fecha_corte_rating'])}"
                      if pd.notna(p["rating"]) else sin_rating))

    n_pend = int(p["n_consultas_pendientes"])
    t_res, t_lin, t_gar, t_con, t_ori = st.tabs([
        "Resumen", f"Líneas ({len(d['lineas'])})", f"Garantías ({len(d['garantias'])})",
        f"Consultas ({int(p['n_consultas'])} · {n_pend} pendientes)", "Origen de los datos"])

    with t_res:
        a, b = st.columns(2)
        with a:
            ficha("Cliente", [
                ("Código", p["cod_cliente"]), ("RUC", p["ruc"]), ("Segmento", p["segmento"]),
                ("Grupo económico", f"{p['cod_grupo_economico']} · {p['nombre_grupo']}"
                 if pd.notna(p["cod_grupo_economico"]) else "sin grupo"),
                ("Sector", fmt_valor(p["sector"]))])
            ficha("Propuesta", [
                ("Ingreso", fmt_fecha(p["fecha_ingreso"])), ("Asignación", fmt_fecha(p["fecha_asignacion"])),
                ("Resolución", fmt_fecha(p["fecha_resolucion"])), ("Prioridad", fmt_valor(p["prioridad"])),
                ("Equipo", fmt_valor(p["equipo"])),
                ("Cobertura de garantías", fmt_valor(p["cobertura_pct"], " %"))])
        with b:
            ficha(f"Riesgo del cliente (foto del {fmt_fecha(p['fecha_corte_riesgo'])})", [
                ("Deuda directa", fmt_monto(p["deuda_directa"])),
                ("Deuda indirecta", fmt_monto(p["deuda_indirecta"])),
                ("Clasificación", fmt_valor(p["clasificacion"])),
                ("Líneas utilizadas", fmt_monto(p["lineas_utilizadas"]))])
            if pd.notna(p["cod_grupo_economico"]):
                ficha("Riesgo del grupo económico", [
                    ("Exposición total", fmt_monto(p["exposicion_grupo"])),
                    ("Límite del grupo", fmt_monto(p["limite_grupo"])),
                    ("Uso del límite", fmt_valor(p["pct_uso_limite_grupo"], " %"))])

    with t_lin:
        if fecha:
            st.caption("Las líneas vienen del DWH sin historia: se muestran con su valor actual.")
        st.dataframe(d["lineas"], hide_index=True, width="stretch", column_config={
            "monto": st.column_config.NumberColumn("monto", format="localized"),
            "fecha_vencimiento": st.column_config.DateColumn("vencimiento", format="DD/MM/YYYY"),
            "fecha_corte_renovacion": st.column_config.DateColumn("archivo de renovación", format="DD/MM/YYYY")})
        if (d["lineas"]["renovacion"] == "SIN DATO").any():
            st.caption("SIN DATO: la propuesta es anterior al primer archivo de renovaciones.")

    with t_gar:
        if d["garantias"].empty:
            st.info("La propuesta no tiene garantías registradas.")
        else:
            st.dataframe(d["garantias"], hide_index=True, width="stretch", column_config={
                "valor_comercial": st.column_config.NumberColumn("valor comercial", format="localized"),
                "valor_realizacion": st.column_config.NumberColumn("valor de realización", format="localized"),
                "cobertura_pct": st.column_config.NumberColumn("cobertura %", format="%.2f")})

    with t_con:
        cons = consultas_a_fecha(d["consultas"], p["fecha_evaluacion"] if fecha else None)
        if cons.empty:
            st.info("Sin consultas a esta fecha.")
        else:
            st.dataframe(cons.drop(columns=["fecha_corte_primera", "fecha_corte_ultima"]), hide_index=True,
                         width="stretch", column_config={
                             "fecha_pregunta": st.column_config.DateColumn("pregunta el", format="DD/MM/YYYY"),
                             "fecha_respuesta": st.column_config.DateColumn("respuesta el", format="DD/MM/YYYY"),
                             "pregunta": st.column_config.TextColumn("pregunta", width="large"),
                             "respuesta": st.column_config.TextColumn("respuesta", width="large")})

    with t_ori:
        st.caption("De dónde sale cada parte de la ficha. Antes había que abrir cada fuente por separado.")
        lin, con = d["lineas"], d["consultas"]
        cortes_ren = lin["fecha_corte_renovacion"].dropna()
        origen = pd.DataFrame([
            ("Propuesta, montos y estado", "DWH corporativo", "—"),
            ("Analista, asignación y prioridad", "Base local del área", "—"),
            ("Líneas", "DWH corporativo + archivo renovacion_lineas",
             f"archivo del {fmt_fecha(cortes_ren.max())}" if not cortes_ren.empty else "sin archivo de renovaciones"),
            ("Garantías", "DWH corporativo", "—"),
            ("Consultas", "archivos consultas_propuesta",
             f"del {fmt_fecha(con['fecha_corte_primera'].min())} al {fmt_fecha(con['fecha_corte_ultima'].max())}"
             if not con.empty else "sin consultas"),
            ("Rating", "archivo rating_cliente", f"foto del {fmt_fecha(p['fecha_corte_rating'])}"),
            ("Riesgo del cliente y del grupo", "DWH corporativo (foto diaria)",
             f"foto del {fmt_fecha(p['fecha_corte_riesgo'])}"),
        ], columns=["Sección", "Fuente", "Fecha de corte"])
        st.dataframe(origen, hide_index=True, width="stretch")


def main() -> None:
    st.set_page_config(page_title="Buscador 360", page_icon="🔎", layout="wide")
    st.title("Buscador 360 de propuestas")
    st.caption("Admisión de Riesgos Corporativos · propuesta, líneas, garantías, consultas, rating y riesgos "
               "en un solo lugar")

    try:
        datos = estado_datos()
    except Exception as e:  # sin conexión: mensaje claro en vez de la traza completa
        st.error(f"No se pudo conectar a {settings()['bases']['integrado']}. Revisa .env y que SQL Server esté "
                 f"en marcha.\n\n{e}")
        st.stop()

    tipo, texto, fecha = barra_lateral(datos)
    try:
        filtro = interpretar_busqueda(tipo, texto)
    except ValueError as e:
        st.warning(str(e))
        st.stop()

    t0 = time.perf_counter()
    res = buscar(filtro, fecha)
    ms = (time.perf_counter() - t0) * 1000

    if filtro is None:
        c = st.columns(3)
        c[0].metric("Propuestas", int(datos["propuestas"]))
        c[1].metric("En evaluación", int(datos["en_evaluacion"]))
        c[2].metric("Datos al", fmt_fecha(datos["hasta"]))
        st.markdown("Escribe un número de propuesta, un cliente o un grupo en la barra lateral, "
                    "o elige una propuesta en evaluación:")
    else:
        st.caption(f"{len(res)} propuesta(s) para {filtro.descripcion} · búsqueda resuelta en {ms:.0f} ms")

    if res.empty:
        st.info("No se encontraron propuestas" + (f" al {fecha:%d/%m/%Y}." if fecha else "."))
        return
    if len(res) == MAX_RESULTADOS:
        st.caption(f"Se muestran las {MAX_RESULTADOS} más recientes; afina la búsqueda para ver otras.")

    if len(res) == 1:
        elegida = int(res.iloc[0]["id_propuesta"])
    else:
        st.caption("Haz clic en una fila para ver su ficha 360.")
        evento = st.dataframe(
            res, hide_index=True, width="stretch", on_select="rerun", selection_mode="single-row",
            key=f"resultados|{tipo}|{texto}|{fecha}",
            column_config={
                "id_propuesta": st.column_config.NumberColumn("propuesta", format="%d"),
                "fecha_ingreso": st.column_config.DateColumn("ingreso", format="DD/MM/YYYY"),
                "monto_solicitado": st.column_config.NumberColumn("monto solicitado", format="localized"),
                "n_consultas_pendientes": st.column_config.NumberColumn("consultas pendientes")})
        filas = evento.selection.rows
        if not filas:
            return
        elegida = int(res.iloc[filas[0]]["id_propuesta"])

    st.divider()
    mostrar_ficha(ficha_360(elegida, fecha), fecha, datos["primer_rating"])


if __name__ == "__main__":
    main()
