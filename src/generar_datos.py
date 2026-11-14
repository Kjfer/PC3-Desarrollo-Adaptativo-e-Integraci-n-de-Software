"""Genera las fuentes simuladas del caso (solo datos sintéticos).

Pasos:
1. Maestros: bancas, grupos económicos, clientes y analistas.
2. Ciclo de vida de cada propuesta: ingreso, asignación, rondas de consultas y resolución.
3. Fotos diarias: rating y riesgo por cliente, riesgo por grupo.
4. Salidas:
   - Tablas de DWH_CORP_SIM y BD_ARC_LOCAL (creadas por sql/02_fuentes_simuladas.sql).
   - data/ruta_compartida/ con un juego de archivos por día:
       consultas_propuesta_ddmmaaaa.csv  (separador ;)
       rating_cliente_ddmmaaaa.xlsx
       renovacion_lineas_ddmmaaaa.txt   (separador |)

Cada archivo es la foto "a la fecha de corte" de las propuestas vivas ese día, por eso
una propuesta resuelta desaparece de los archivos siguientes (hay que buscarla en los
anteriores). Los problemas de calidad se siembran A PROPÓSITO; no corregirlos aquí:
  - consultas: fechas en dd/mm/aaaa y aaaa-mm-dd mezcladas, filas repetidas
  - rating: cod_cliente numérico (pierde ceros), filas de título antes del encabezado
    (algunos días una fila extra)
  - renovaciones: montos con coma decimal, un día sin archivo

Uso:
    python src/generar_datos.py                    # usa config/settings.yaml
    python src/generar_datos.py --dias 30 --fecha-fin 12112026
    python src/generar_datos.py --sin-bd           # solo archivos, sin SQL Server
"""
from __future__ import annotations

import argparse
import random
import re
import sys
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta

import pandas as pd
from openpyxl import Workbook

from config import ruta, settings

# ---------------------------------------------------------------------------
# Catálogos sintéticos
# ---------------------------------------------------------------------------
BANCAS = {"COR": "Corporativa", "INS": "Institucional", "EMP": "Empresa", "INM": "Inmobiliaria"}
PESO_BANCA = {"COR": 0.25, "INS": 0.12, "EMP": 0.45, "INM": 0.18}
ANALISTAS_POR_BANCA = {"COR": 2, "INS": 1, "EMP": 3, "INM": 2}
SEGMENTOS = {
    "COR": ["Gran Corporación", "Corporativo"],
    "INS": ["Institucional", "Sector Público"],
    "EMP": ["Mediana Empresa", "Gran Empresa"],
    "INM": ["Promotor Inmobiliario", "Constructora"],
}
MODELO_RATING = {"COR": "MR-CORPORATIVO", "INS": "MR-INSTITUCIONAL", "EMP": "MR-EMPRESAS", "INM": "MR-INMOBILIARIO"}
# Rango del monto de cada línea (en PEN) por banca
MONTO_LINEA = {"COR": (5e6, 80e6), "INS": (3e6, 40e6), "EMP": (0.3e6, 12e6), "INM": (2e6, 35e6)}
TIPO_CAMBIO = 3.75

SECTORES = ["Minería", "Agroindustria", "Construcción", "Retail", "Energía", "Pesca", "Manufactura",
            "Transporte", "Telecomunicaciones", "Educación", "Inmobiliario", "Salud"]
RAICES = ["Andina", "del Pacífico", "Los Álamos", "San Gabriel", "Altamira", "Río Blanco", "Cordillera",
          "Mirador", "Sol Naciente", "Puerto Nuevo", "Las Lomas", "Santa Clara", "Tres Cruces",
          "Valle Verde", "Horizonte", "El Roble", "Costa Azul", "Nuevo Norte", "Quebrada Alta",
          "Monteverde", "Alto Sur", "La Ensenada", "Piedra Fina", "Cielo Claro", "Los Pinos",
          "Bahía Serena", "Tierra Firme", "Punta Arena", "Vista Real", "Laguna Grande", "Cerro Azul",
          "Nueva Aurora", "Bosque Alto", "Las Dunas", "Río Claro", "Brisa Marina", "Campo Verde",
          "Sierra Plata", "Monte Real", "Valle Sur"]
PREFIJOS = {
    "COR": ["Corporación", "Inversiones", "Industrias", "Minera", "Energía", "Holding"],
    "INS": ["Fondo", "Caja", "Universidad", "Asociación", "Cooperativa"],
    "EMP": ["Comercial", "Distribuidora", "Transportes", "Servicios", "Agroindustrial", "Textil", "Pesquera"],
    "INM": ["Inmobiliaria", "Constructora", "Desarrolladora", "Edificaciones"],
}
SUFIJOS = ["S.A.", "S.A.A.", "S.A.C.", "S.R.L."]
NOMBRES = ["Lucía", "Martín", "Andrea", "Diego", "Valeria", "Jorge", "Camila", "Renato", "Paola", "Sergio"]
APELLIDOS = ["Quispe", "Salazar", "Vargas", "Herrera", "Castillo", "Mendoza", "Rojas", "Paredes",
             "Navarro", "Gutiérrez"]

TIPOS_LINEA = ["Préstamo comercial", "Carta fianza", "Capital de trabajo", "Leasing",
               "Comercio exterior", "Factoring"]
TIPO_LINEA_INM = "Promoción inmobiliaria"
TIPOS_GARANTIA = ["Hipoteca", "Prenda vehicular", "Prenda de maquinaria", "Fianza solidaria",
                  "Depósito en garantía", "Warrant", "Fideicomiso de flujos"]

RATINGS = ["AAA", "AA", "A", "BBB", "BB", "B", "CCC"]
PESO_RATING = [0.05, 0.15, 0.25, 0.25, 0.15, 0.10, 0.05]
CLASIFICACION = ["NOR", "NOR", "NOR", "NOR", "NOR", "CPP", "DEF"]  # por índice de rating

PREGUNTAS = [
    "Sustentar el destino de los fondos solicitados.",
    "Remitir EEFF auditados del último ejercicio.",
    "Explicar la caída de ventas del último trimestre.",
    "Detallar el cronograma de pagos de la deuda vigente.",
    "Indicar el valor de tasación actualizado de la garantía.",
    "Confirmar la participación de los accionistas en el grupo económico.",
    "Sustentar el flujo de caja proyectado para el plazo solicitado.",
    "Aclarar el incremento de la deuda indirecta en el sistema financiero.",
    "Remitir el contrato de obra que respalda la carta fianza.",
    "Explicar la clasificación CPP registrada en otra entidad.",
    "Indicar las condiciones de las líneas vigentes con otros bancos.",
]
PREGUNTA_INM = "Detallar el avance de ventas y preventas del proyecto inmobiliario."
RESPUESTAS = [
    "Se adjunta el sustento solicitado.",
    "El cliente remitió la información; se encuentra en el expediente.",
    "La variación se explica por la estacionalidad del negocio.",
    "Se actualizó la tasación con fecha reciente.",
    "El funcionario de negocio confirmó la información con el cliente.",
    "Se adjunta el cronograma y el flujo de caja proyectado.",
    "La deuda indirecta corresponde a cartas fianza de obras en curso.",
]
OPINION = {"APROBADA": "APROBAR", "OBSERVADA": "OBSERVAR", "DENEGADA": "DENEGAR"}

PATRON_GENERADOS = re.compile(r"^(consultas_propuesta|rating_cliente|renovacion_lineas)_\d{8}\.(csv|xlsx|txt)$")
COLS_CONSULTAS = ["id_propuesta", "nro_consulta", "ronda", "fecha_pregunta", "pregunta",
                  "fecha_respuesta", "respuesta", "estado"]
COLS_RATING = ["cod_cliente", "rating", "modelo_rating", "fecha_rating"]
COLS_RENOVACION = ["id_propuesta", "id_linea", "tipo_linea", "monto", "plazo_meses",
                   "fecha_vencimiento", "es_renovacion"]


# ---------------------------------------------------------------------------
# Estructuras
# ---------------------------------------------------------------------------
@dataclass
class Consulta:
    nro: int
    ronda: int
    fecha_pregunta: date
    pregunta: str
    fecha_respuesta: date | None
    respuesta: str | None


@dataclass
class Propuesta:
    id: int
    cod_cliente: str
    cod_banca: str
    tipo: str
    fecha_ingreso: date
    moneda: str
    cod_analista: str
    fecha_asignacion: date
    prioridad: str
    estado: str = "EN EVALUACION"
    fecha_resolucion: date | None = None
    monto_solicitado: float = 0.0
    monto_aprobado: float | None = None
    lineas: list[dict] = field(default_factory=list)
    garantias: list[dict] = field(default_factory=list)
    consultas: list[Consulta] = field(default_factory=list)

    def viva(self, d: date) -> bool:
        """Aparece en los archivos del día d: ya ingresó y no se resolvió antes de d."""
        return self.fecha_ingreso <= d and (self.fecha_resolucion is None or d <= self.fecha_resolucion)


def _dias(d: date, n: int) -> date:
    return d + timedelta(days=n)


def _hora(rng: random.Random, d: date, desde: int, hasta: int) -> datetime:
    return datetime.combine(d, time(rng.randint(desde, hasta), rng.randint(0, 59)))


# ---------------------------------------------------------------------------
# Generador
# ---------------------------------------------------------------------------
class Generador:
    def __init__(self, cfg: dict, fecha_fin: date, dias: int, semilla: int):
        self.cfg = cfg
        self.rng = random.Random(semilla)
        self.fecha_fin = fecha_fin
        self.fechas = [_dias(fecha_fin, -i) for i in range(dias - 1, -1, -1)]
        self.fecha_inicio = self.fechas[0]

    # -- maestros -----------------------------------------------------------
    def maestros(self) -> None:
        rng, cfg = self.rng, self.cfg
        raices = RAICES[:]
        rng.shuffle(raices)
        n_grupos = cfg["n_grupos"]
        self.grupos = [
            {"cod_grupo_economico": f"GE{i + 1:04d}", "nombre_grupo": f"Grupo {raices[i]}",
             "sector": rng.choice(SECTORES), "_raiz": raices[i]}
            for i in range(n_grupos)
        ]
        raices_sueltas = raices[n_grupos:] or RAICES

        codigos = rng.sample(range(1_000, 99_999), cfg["n_clientes"])  # 4-5 dígitos: ceros a la izquierda
        n_con_grupo = round(cfg["n_clientes"] * cfg["pct_clientes_con_grupo"])
        usados: set[str] = set()
        self.clientes = []
        for i, cod in enumerate(codigos):
            banca = rng.choices(list(PESO_BANCA), list(PESO_BANCA.values()))[0]
            # Los primeros n_grupos clientes con grupo garantizan que ningún grupo quede vacío
            grupo = None
            if i < n_con_grupo:
                grupo = self.grupos[i] if i < n_grupos else rng.choice(self.grupos)
            while True:
                raiz = grupo["_raiz"] if grupo and rng.random() < 0.8 else rng.choice(raices_sueltas)
                nombre = f"{rng.choice(PREFIJOS[banca])} {raiz} {rng.choice(SUFIJOS)}"
                if nombre not in usados:
                    usados.add(nombre)
                    break
            self.clientes.append({
                "cod_cliente": f"{cod:08d}",
                "razon_social": nombre,
                "ruc": "20" + "".join(str(rng.randint(0, 9)) for _ in range(9)),
                "segmento": rng.choice(SEGMENTOS[banca]),
                "cod_banca": banca,
                "cod_grupo_economico": grupo["cod_grupo_economico"] if grupo else None,
                "fecha_alta": _dias(self.fecha_inicio, -rng.randint(365, 15 * 365)),
            })
        rng.shuffle(self.clientes)

        self.analistas, self.analistas_por_banca = [], {}
        nombres = [f"{n} {a}" for n in NOMBRES for a in APELLIDOS]
        rng.shuffle(nombres)
        for banca, n in ANALISTAS_POR_BANCA.items():
            for _ in range(n):
                cod = f"AN{len(self.analistas) + 1:03d}"
                self.analistas.append({"cod_analista": cod, "nombre": nombres.pop(),
                                       "equipo": f"Equipo {BANCAS[banca]}", "activo": True})
                self.analistas_por_banca.setdefault(banca, []).append(cod)

    # -- fotos diarias: rating y riesgo ----------------------------------------
    def fotos_diarias(self) -> None:
        rng = self.rng
        self.rating: dict[tuple[str, date], tuple[int, date]] = {}
        self.riesgo_cliente, self.riesgo_grupo = [], []
        estado = {}
        for c in self.clientes:
            lo, hi = MONTO_LINEA[c["cod_banca"]]
            directa = rng.uniform(lo, hi) * rng.uniform(1, 4)
            estado[c["cod_cliente"]] = {
                "idx": rng.choices(range(len(RATINGS)), PESO_RATING)[0],
                "fecha_rating": _dias(self.fecha_inicio, -rng.randint(10, 300)),
                "directa": directa,
                "ratio_ind": rng.uniform(0.1, 0.6),
                "uso": rng.uniform(0.75, 0.95),
            }
        limites: dict[str, float] = {}
        for d in self.fechas:
            expo_grupo: dict[str, float] = {}
            for c in self.clientes:
                e = estado[c["cod_cliente"]]
                if d > self.fecha_inicio and rng.random() < 0.015:  # cambio de rating ocasional
                    e["idx"] = min(max(e["idx"] + rng.choice([-1, 1]), 0), len(RATINGS) - 1)
                    e["fecha_rating"] = d
                e["directa"] *= 1 + rng.gauss(0, 0.01)
                indirecta = e["directa"] * e["ratio_ind"] * (1 + rng.gauss(0, 0.02))
                self.rating[(c["cod_cliente"], d)] = (e["idx"], e["fecha_rating"])
                self.riesgo_cliente.append({
                    "fecha_corte": d, "cod_cliente": c["cod_cliente"],
                    "deuda_directa": round(e["directa"], 2), "deuda_indirecta": round(indirecta, 2),
                    "clasificacion": CLASIFICACION[e["idx"]],
                    "lineas_utilizadas": round((e["directa"] + indirecta) * e["uso"], 2),
                })
                if c["cod_grupo_economico"]:
                    g = c["cod_grupo_economico"]
                    expo_grupo[g] = expo_grupo.get(g, 0) + e["directa"] + indirecta
            for g, expo in sorted(expo_grupo.items()):
                limites.setdefault(g, expo * rng.uniform(1.2, 1.8))
                self.riesgo_grupo.append({"fecha_corte": d, "cod_grupo_economico": g,
                                          "exposicion_total": round(expo, 2),
                                          "limite_grupo": round(limites[g], 2)})

    # -- propuestas -----------------------------------------------------------
    def propuestas(self) -> None:
        rng, cfg = self.rng, self.cfg
        fechas_ingreso = sorted(_dias(self.fecha_inicio, -rng.randint(1, 20))
                                for _ in range(cfg["propuestas_previas"]))
        lo, hi = cfg["propuestas_por_dia"]
        for d in self.fechas:
            fechas_ingreso += [d] * rng.randint(lo, hi)

        self.lista: list[Propuesta] = []
        self.id_linea, self.id_garantia = 1_000_000, 800_000
        for i, f_ing in enumerate(fechas_ingreso):
            self.lista.append(self._propuesta(260_001 + i, f_ing))

    def _propuesta(self, id_prop: int, f_ing: date) -> Propuesta:
        rng = self.rng
        cli = rng.choice(self.clientes)
        banca = cli["cod_banca"]
        tipo = rng.choices(["NUEVA", "RENOVACION", "AMPLIACION"], [0.35, 0.45, 0.20])[0]
        moneda = rng.choices(["PEN", "USD"], [0.6, 0.4])[0]
        f_asig = _dias(f_ing, rng.choice([0, 0, 1]))
        p = Propuesta(id=id_prop, cod_cliente=cli["cod_cliente"], cod_banca=banca, tipo=tipo,
                      fecha_ingreso=f_ing, moneda=moneda,
                      cod_analista=rng.choice(self.analistas_por_banca[banca]),
                      fecha_asignacion=f_asig,
                      prioridad=rng.choices(["ALTA", "MEDIA", "BAJA"], [0.2, 0.5, 0.3])[0])

        # Líneas
        lo, hi = MONTO_LINEA[banca]
        factor = 1 / TIPO_CAMBIO if moneda == "USD" else 1
        tipos = TIPOS_LINEA + ([TIPO_LINEA_INM] * 3 if banca == "INM" else [])
        prob_renov = {"NUEVA": 0.0, "RENOVACION": 0.85, "AMPLIACION": 0.4}[tipo]
        for _ in range(rng.choices([1, 2, 3, 4], [0.4, 0.3, 0.2, 0.1])[0]):
            self.id_linea += 1
            tipo_linea = rng.choice(tipos)
            plazo = rng.choice([6, 12]) if tipo_linea == "Carta fianza" else rng.choice([12, 18, 24, 36, 60])
            es_renov = rng.random() < prob_renov
            venc = _dias(f_ing, rng.randint(5, 60)) if es_renov else _dias(f_ing, round(plazo * 30.4))
            p.lineas.append({"id_linea": self.id_linea, "tipo_linea": tipo_linea,
                             "monto": round(rng.uniform(lo, hi) * factor, 2), "plazo_meses": plazo,
                             "fecha_vencimiento": venc, "es_renovacion": es_renov})
        p.monto_solicitado = round(sum(l["monto"] for l in p.lineas), 2)

        # Garantías
        for _ in range(rng.choices([0, 1, 2, 3], [0.25, 0.4, 0.25, 0.1])[0]):
            self.id_garantia += 1
            vc = round(p.monto_solicitado * rng.uniform(0.2, 0.8), 2)
            vr = round(vc * rng.uniform(0.6, 0.85), 2)
            p.garantias.append({"id_garantia": self.id_garantia, "tipo_garantia": rng.choice(TIPOS_GARANTIA),
                                "valor_comercial": vc, "valor_realizacion": vr,
                                "cobertura_pct": round(min(vr / p.monto_solicitado * 100, 999.99), 2)})

        # Rondas de consultas y resolución
        preguntas = PREGUNTAS + ([PREGUNTA_INM] if banca == "INM" else [])
        n_rondas = rng.choices([0, 1, 2, 3], [0.3, 0.4, 0.2, 0.1])[0]
        t, nro = _dias(f_asig, rng.randint(1, 3)), 0
        for ronda in range(1, n_rondas + 1):
            ultima = t
            for texto in rng.sample(preguntas, rng.randint(1, 4)):
                nro += 1
                f_resp = _dias(t, rng.randint(1, 4))
                p.consultas.append(Consulta(nro, ronda, t, texto, f_resp, rng.choice(RESPUESTAS)))
                ultima = max(ultima, f_resp)
            t = _dias(ultima, rng.randint(1, 2))
        f_resol = _dias(t if n_rondas else _dias(f_asig, rng.randint(2, 5)), rng.randint(0, 2))
        estado_final = rng.choices(["APROBADA", "OBSERVADA", "DENEGADA"], [0.6, 0.2, 0.2])[0]

        # Cortar todo lo que ocurriría después del último día simulado
        p.consultas = [c for c in p.consultas if c.fecha_pregunta <= self.fecha_fin]
        for c in p.consultas:
            if c.fecha_respuesta > self.fecha_fin:
                c.fecha_respuesta, c.respuesta = None, None
        if f_resol <= self.fecha_fin:
            p.fecha_resolucion, p.estado = f_resol, estado_final
            if estado_final == "APROBADA":
                p.monto_aprobado = round(p.monto_solicitado * rng.choice([1, 1, 1, rng.uniform(0.7, 1)]), 2)
            elif estado_final == "OBSERVADA":
                p.monto_aprobado = round(p.monto_solicitado * rng.uniform(0.5, 0.9), 2)
        return p

    # -- tablas de las bases simuladas -------------------------------------------
    def tablas_dwh(self) -> dict[str, pd.DataFrame]:
        prop, lin, gar = [], [], []
        for p in self.lista:
            prop.append({"id_propuesta": p.id, "cod_cliente": p.cod_cliente, "cod_banca": p.cod_banca,
                         "tipo_propuesta": p.tipo, "fecha_ingreso": p.fecha_ingreso,
                         "fecha_resolucion": p.fecha_resolucion, "estado": p.estado, "moneda": p.moneda,
                         "monto_solicitado": p.monto_solicitado, "monto_aprobado": p.monto_aprobado,
                         "fecha_actualizacion": p.fecha_resolucion or p.fecha_ingreso})
            # El DWH no conoce el indicador de renovación: ese dato llega en el archivo de la ruta
            lin += [{"id_propuesta": p.id, "id_linea": l["id_linea"], "tipo_linea": l["tipo_linea"],
                     "moneda": p.moneda, "monto": l["monto"], "plazo_meses": l["plazo_meses"],
                     "fecha_vencimiento": l["fecha_vencimiento"]} for l in p.lineas]
            gar += [{"id_propuesta": p.id, "moneda": p.moneda, **g} for g in p.garantias]
        return {  # en orden de carga
            "banca": pd.DataFrame([{"cod_banca": k, "nombre_banca": v} for k, v in BANCAS.items()]),
            "grupo_economico": pd.DataFrame(self.grupos).drop(columns="_raiz"),
            "cliente": pd.DataFrame(self.clientes),
            "propuesta": pd.DataFrame(prop),
            "propuesta_linea": pd.DataFrame(lin),
            "garantia": pd.DataFrame(gar),
            "riesgo_cliente": pd.DataFrame(self.riesgo_cliente),
            "riesgo_grupo": pd.DataFrame(self.riesgo_grupo),
        }

    def tablas_local(self) -> dict[str, pd.DataFrame]:
        rng = self.rng
        asig, seg = [], []

        def evento(p: Propuesta, cuando: datetime, ev: str, comentario: str | None = None) -> None:
            if cuando.date() <= self.fecha_fin:
                seg.append({"id_propuesta": p.id, "fecha_evento": cuando, "evento": ev,
                            "cod_analista": p.cod_analista, "comentario": comentario})

        for p in self.lista:
            if p.fecha_asignacion > self.fecha_fin:
                continue
            asig.append({"id_propuesta": p.id, "cod_analista": p.cod_analista,
                         "fecha_asignacion": p.fecha_asignacion, "prioridad": p.prioridad})
            evento(p, _hora(rng, p.fecha_asignacion, 8, 10), "ASIGNADA")
            evento(p, _hora(rng, p.fecha_asignacion, 11, 17), "EN REVISION")
            for ronda in sorted({c.ronda for c in p.consultas}):
                cs = [c for c in p.consultas if c.ronda == ronda]
                evento(p, _hora(rng, cs[0].fecha_pregunta, 9, 17), "CONSULTA ENVIADA",
                       f"Ronda {ronda}: {len(cs)} consulta(s)")
                if all(c.fecha_respuesta for c in cs):
                    evento(p, _hora(rng, max(c.fecha_respuesta for c in cs), 9, 17), "RESPUESTA RECIBIDA",
                           f"Ronda {ronda} respondida")
            if p.fecha_resolucion:
                evento(p, _hora(rng, p.fecha_resolucion, 16, 18), "OPINION EMITIDA",
                       f"Opinión: {OPINION[p.estado]}")
        seg.sort(key=lambda e: e["fecha_evento"])
        return {
            "analista": pd.DataFrame(self.analistas),
            "asignacion_propuesta": pd.DataFrame(asig),
            "seguimiento_propuesta": pd.DataFrame(seg),
        }

    # -- archivos de la ruta compartida ------------------------------------------
    def archivos(self, carpeta) -> dict[str, int]:
        rng, cfg = self.rng, self.cfg
        carpeta.mkdir(parents=True, exist_ok=True)
        for f in carpeta.iterdir():  # solo borra archivos generados antes
            if f.is_file() and PATRON_GENERADOS.match(f.name):
                f.unlink()

        dia_sin_renovacion = rng.choice(self.fechas[5:-5] or self.fechas)
        conteo = {"consultas": 0, "rating": 0, "renovacion": 0}
        self.dia_sin_renovacion = dia_sin_renovacion
        self.dias_fila_extra = []
        for d in self.fechas:
            sufijo = d.strftime("%d%m%Y")
            vivas = [p for p in self.lista if p.viva(d)]

            # consultas_propuesta: CSV ; con formatos de fecha mezclados y filas repetidas
            filas = []
            for p in vivas:
                for c in p.consultas:
                    if c.fecha_pregunta > d:
                        continue
                    respondida = c.fecha_respuesta is not None and c.fecha_respuesta <= d
                    fmt = "%Y-%m-%d" if rng.random() < cfg["pct_fecha_iso_consultas"] else "%d/%m/%Y"
                    filas.append([p.id, c.nro, c.ronda, c.fecha_pregunta.strftime(fmt), c.pregunta,
                                  c.fecha_respuesta.strftime(fmt) if respondida else "",
                                  c.respuesta if respondida else "",
                                  "RESPONDIDA" if respondida else "PENDIENTE"])
            for fila in [f for f in filas if rng.random() < cfg["pct_duplicados_consultas"]]:
                filas.insert(rng.randint(0, len(filas)), list(fila))
            pd.DataFrame(filas, columns=COLS_CONSULTAS).to_csv(
                carpeta / f"consultas_propuesta_{sufijo}.csv", sep=";", index=False, encoding="utf-8")
            conteo["consultas"] += 1

            # rating_cliente: Excel con filas de título y cod_cliente numérico
            wb = Workbook()
            ws = wb.active
            ws.title = "Rating"
            ws.append(["REPORTE DE RATING DE CLIENTES EN PROPUESTA"])
            ws.append([f"Fecha de corte: {d:%d/%m/%Y}"])
            if rng.random() < cfg["pct_dias_fila_extra_rating"]:
                ws.append(["Fuente: modelo interno de rating - uso interno"])
                self.dias_fila_extra.append(d)
            ws.append([])
            ws.append(COLS_RATING)
            bancas = {p.cod_cliente: p.cod_banca for p in vivas}
            for cod in sorted(bancas):
                idx, f_rating = self.rating[(cod, d)]
                ws.append([int(cod), RATINGS[idx], MODELO_RATING[bancas[cod]], f_rating])
                ws.cell(row=ws.max_row, column=4).number_format = "DD/MM/YYYY"
            wb.save(carpeta / f"rating_cliente_{sufijo}.xlsx")
            conteo["rating"] += 1

            # renovacion_lineas: texto | con coma decimal; un día no llega
            if d == dia_sin_renovacion:
                continue
            filas = [[p.id, l["id_linea"], l["tipo_linea"], f"{l['monto']:.2f}".replace(".", ","),
                      l["plazo_meses"], l["fecha_vencimiento"].strftime("%d/%m/%Y"),
                      "S" if l["es_renovacion"] else "N"]
                     for p in vivas for l in p.lineas]
            pd.DataFrame(filas, columns=COLS_RENOVACION).to_csv(
                carpeta / f"renovacion_lineas_{sufijo}.txt", sep="|", index=False, encoding="utf-8")
            conteo["renovacion"] += 1
        return conteo


# ---------------------------------------------------------------------------
# Carga a SQL Server
# ---------------------------------------------------------------------------
def cargar_bd(base: str, tablas: dict[str, pd.DataFrame]) -> None:
    from sqlalchemy.exc import DBAPIError

    from db import motor

    try:
        with motor(base).begin() as cn:
            for nombre in tablas:
                cn.exec_driver_sql(f"TRUNCATE TABLE dbo.{nombre}")
            for nombre, df in tablas.items():
                df.to_sql(nombre, cn, schema="dbo", if_exists="append", index=False, chunksize=1000)
    except DBAPIError as e:
        sys.exit(f"Error al cargar {base}: {e.orig}\n"
                 "¿Se crearon las bases y tablas? Ejecute: python src/run_pipeline.py --init")


def main() -> None:
    # La consola de Windows usa cp1252/cp850 al redirigir la salida (pipe, log); forzar UTF-8 conserva los acentos
    sys.stdout.reconfigure(encoding="utf-8")
    cfg = settings()["simulacion"]
    ap = argparse.ArgumentParser(description="Genera las fuentes simuladas del caso (datos sintéticos).")
    ap.add_argument("--dias", type=int, default=cfg["dias"], help="días de archivos a generar")
    ap.add_argument("--fecha-fin", help="último día con archivos, ddmmaaaa (por defecto settings.yaml)")
    ap.add_argument("--semilla", type=int, default=cfg["semilla"])
    ap.add_argument("--sin-bd", action="store_true", help="solo genera archivos; no escribe en SQL Server")
    args = ap.parse_args()

    fecha_fin = (datetime.strptime(args.fecha_fin, "%d%m%Y").date() if args.fecha_fin
                 else cfg["fecha_fin"])
    gen = Generador(cfg, fecha_fin, args.dias, args.semilla)
    gen.maestros()
    gen.fotos_diarias()
    gen.propuestas()
    dwh, local = gen.tablas_dwh(), gen.tablas_local()
    conteo = gen.archivos(ruta("ruta_compartida"))

    print(f"Periodo simulado: {gen.fecha_inicio:%d/%m/%Y} - {gen.fecha_fin:%d/%m/%Y} ({args.dias} días)")
    print(f"Archivos en {ruta('ruta_compartida')}: {conteo}")
    print(f"  Día sin archivo de renovaciones: {gen.dia_sin_renovacion:%d/%m/%Y}")
    print(f"  Días con fila de título extra en rating: {[f'{d:%d/%m}' for d in gen.dias_fila_extra]}")
    if args.sin_bd:
        print("Carga a SQL Server omitida (--sin-bd).")
        return
    nombres = settings()["bases"]
    cargar_bd(nombres["dwh_sim"], dwh)
    cargar_bd(nombres["local"], local)
    for base, tablas in ((nombres["dwh_sim"], dwh), (nombres["local"], local)):
        print(f"{base}: " + ", ".join(f"{n}={len(df)}" for n, df in tablas.items()))


if __name__ == "__main__":
    main()
