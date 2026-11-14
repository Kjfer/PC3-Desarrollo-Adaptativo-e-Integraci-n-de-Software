# Proyecto de Integración de Datos – Admisión de Riesgos Corporativos

Nov 12, 2026 · @Gary Fernandez

## 1. Caso: Admisión de Riesgos Corporativos

El área de Admisión de Riesgos Corporativos de un banco evalúa cada día las propuestas de crédito de cuatro bancas: Corporativa, Institucional, Empresa e Inmobiliaria. Para emitir una opinión (aprobar, observar o denegar), el analista necesita ver en un mismo momento la propuesta, las líneas y su renovación, las garantías, el riesgo del cliente y de su grupo económico, el rating vigente y el historial de consultas.

Esa información hoy vive en tres lugares distintos, con formatos, llaves y frecuencias diferentes:

| Origen | Qué contiene | Formato y frecuencia | Cómo se usa hoy |
| --- | --- | --- | --- |
| Datawarehouse corporativo | Propuestas, líneas, garantías, riesgo de cliente, riesgo grupal | Tablas listas para consumir, carga diaria | Consultas SQL puntuales o extracciones a Excel |
| Base local del área (SQL Server) | Tablas propias del área: seguimiento, asignaciones y cargas manuales | Tablas relacionales, actualización variable | Consultas del equipo y reportes internos |
| Ruta de red compartida | Consultas de la propuesta (preguntas y respuestas hasta su aprobación o denegación), rating del cliente en la propuesta, renovación de líneas, otros reportes | Archivos CSV, Excel y texto plano con la fecha en el nombre: `nombre_ddmmaaaa` | Se abren a mano, archivo por archivo, buscando la fecha y el cliente |

Cada día llega una nueva versión de los archivos de la ruta, por lo que la carpeta acumula cientos de copias del mismo reporte con fechas distintas. Ninguna de esas copias está unida al datawarehouse ni a la base local: la relación entre una consulta, un rating y una propuesta solo existe en la cabeza del analista.

> Supuesto del caso: el contenido exacto de la base local se generaliza como “tablas propias del área”; en el demo se simula con tablas de seguimiento y asignación de propuestas.

## 2. Problemática central

**Problema central:** la información necesaria para evaluar una propuesta está dispersa entre el datawarehouse, la base local y cientos de archivos diarios sin una llave común ni un historial consolidado, lo que obliga a búsquedas manuales que retrasan la evaluación y exponen al área a errores.

Un caso típico: para revisar la renovación de líneas de un cliente de Banca Empresa, el analista consulta la propuesta en el DWH, busca en la ruta el archivo de consultas de la fecha correcta, abre otro archivo para ver el rating que tenía el cliente en ese momento y cruza todo a mano en Excel. Si la propuesta tuvo varias rondas de consultas, repite la búsqueda en varios archivos de distintas fechas.

| Problema específico | Causa | Efecto en el área |
| --- | --- | --- |
| Demora en la búsqueda de datos | No hay un punto único de consulta; los archivos se buscan por nombre y fecha | Más tiempo por propuesta y menor capacidad de atención |
| Versiones diarias sin consolidar | Cada día llega un archivo nuevo `nombre_ddmmaaaa`; no se historiza en tablas | No se puede reconstruir el estado de una propuesta en una fecha dada |
| Datos que no cruzan | Códigos de cliente y de propuesta con formatos distintos (ceros a la izquierda, texto vs número) | Cruces fallidos o duplicados al unir fuentes |
| Formatos heterogéneos | Fechas en varios formatos, separadores distintos en CSV, Excel con encabezados o hojas variables | Errores de lectura y reprocesos manuales |
| Sin trazabilidad ni control de calidad | No se registra qué archivo se cargó, cuándo ni con cuántas filas | Archivos faltantes o vacíos pasan desapercibidos; riesgo ante auditoría |
| Dependencia de personas | El conocimiento de dónde está cada dato y cómo cruzarlo es tácito | Continuidad frágil ante rotación o ausencias |
| Reportes inconsistentes | Cada analista arma su propio Excel con cortes distintos | Cifras diferentes para la misma propuesta o cliente |

El demo medirá el tiempo de búsqueda de una propuesta antes y después de la integración como indicador principal.

## 3. Objetivos

**Objetivo general:** integrar en un único almacén en SQL Server los datos del DWH, de la base local y de los archivos de la ruta compartida, para que el área consulte la información completa de una propuesta desde un solo punto.

**Objetivos específicos:**

1. Automatizar la ingesta diaria de los archivos `nombre_ddmmaaaa`, tomando la fecha de corte del nombre y registrando cada carga.
2. Estandarizar llaves (propuesta, cliente, grupo económico), fechas y tipos de dato entre las tres fuentes.
3. Historizar la información por fecha de corte para reconstruir el estado de una propuesta en cualquier día.
4. Aplicar reglas de calidad y alertar archivos faltantes, vacíos o con errores.
5. Exponer una vista 360 de la propuesta y un buscador que reduzca el tiempo de búsqueda.

## 4. Arquitectura de la solución

La solución es un almacén integrado en SQL Server con tres zonas (Raw, Staging e Integrado), alimentado por dos procesos de ingesta y gobernado por una capa transversal de orquestación, auditoría y calidad.

&#91;embedded content: arquitectura de integración · 4 capas + transversal\]

Los datos bajan de las fuentes a la ingesta, pasan por Raw y Staging, y llegan al modelo integrado que alimenta el buscador, Power BI y las vistas SQL; la capa transversal controla todo el recorrido.

### Componentes por capa

| Capa | Componente | Función | Tecnología (producción) | Tecnología (demo) |
| --- | --- | --- | --- | --- |
| 1. Fuentes | DWH corporativo, base local, ruta compartida | Origen de propuestas, líneas, garantías, riesgos, consultas y rating | SQL Server / DWH existente, carpeta de red | SQL Server local + carpeta `data/ruta_compartida` con archivos simulados |
| 2. Ingesta | Extractor de bases | Carga incremental desde DWH y base local usando la fecha de corte como marca de agua | SSIS o Azure Data Factory | Python (`pyodbc` / `SQLAlchemy`) |
| 2. Ingesta | Lector de archivos | Detecta archivos nuevos por patrón `nombre_ddmmaaaa`, extrae la fecha, calcula un hash para no cargar dos veces | SSIS o ADF con bucle de archivos | Python (`pandas`, `openpyxl`, `re`) |
| 3. Almacén | Raw | Copia fiel de cada fuente, con columnas de control: archivo origen, fecha de corte, fecha de carga | Esquema `raw` en SQL Server | Esquema `raw` |
| 3. Almacén | Staging | Tipifica, limpia, estandariza llaves y fechas, elimina duplicados | Esquema `stg`, procedimientos T-SQL o dbt | Esquema `stg`, procedimientos T-SQL |
| 3. Almacén | Integrado | Modelo dimensional centrado en la propuesta, historizado por fecha de corte | Esquema `dwh` | Esquema `dwh` + vista `vw_propuesta_360` |
| 4. Consumo | Buscador 360, Power BI, vistas SQL | Consulta por propuesta, cliente o grupo; reportes de seguimiento | Power BI Service, vistas SQL | Streamlit + Power BI Desktop |
| Transversal | Orquestación | Ejecuta el flujo diario en orden y reintenta fallos | SQL Server Agent o Airflow | Script `run_pipeline.py` (o Prefect) |
| Transversal | Auditoría y calidad | Registra cada carga (archivo, filas, estado) y valida reglas | Esquema `ctl` | Esquema `ctl` + reglas en Python/SQL |
| Transversal | Catálogo y seguridad | Diccionario de datos, linaje y acceso por rol | Purview o diccionario interno, roles de SQL Server | Diccionario en Markdown, roles de SQL |

### Decisiones de diseño clave

- **Fecha de corte desde el nombre del archivo.** El patrón `^(?P<nombre>.+)_(?P<fecha>\d{8})\.(csv|xlsx|txt)$` separa el tipo de reporte y su fecha `ddmmaaaa`; esa fecha viaja como columna `fecha_corte` en todas las tablas.
- **Carga idempotente.** Cada archivo se registra en `ctl.archivo_cargado` con su hash; si el archivo ya fue cargado, se omite, y si cambió, se recarga solo esa fecha.
- **Llaves de integración.** `id_propuesta`, `cod_cliente` (código único, normalizado a texto de longitud fija) y `cod_grupo_economico` unen las tres fuentes.
- **Historia por fecha.** El rating y los riesgos se guardan como foto diaria; así se puede ver qué rating tenía el cliente el día en que se evaluó la propuesta.
- **ELT dentro de SQL Server.** Python solo mueve datos a Raw; la limpieza y el modelo se hacen en T-SQL, cerca del motor que el área ya usa.
- **Configuración por metadatos.** Una tabla `ctl.fuente_config` describe cada tipo de archivo (patrón, separador, hoja, tabla destino), de modo que agregar un reporte nuevo no requiere código nuevo.

## 5. Modelo de datos integrado

El modelo gira alrededor de la propuesta: cada hecho se une a ella por `id_propuesta` o al cliente por `cod_cliente` y `fecha_corte`, y la vista `vw_propuesta_360` reúne todo en una sola consulta.

| Tabla (esquema `dwh`) | Tipo | Grano (una fila por…) | Llaves | Atributos principales | Fuente |
| --- | --- | --- | --- | --- | --- |
| `dim_cliente` | Dimensión | cliente | `cod_cliente` | razón social, RUC, segmento, banca, `cod_grupo_economico` | DWH |
| `dim_grupo_economico` | Dimensión | grupo económico | `cod_grupo_economico` | nombre del grupo, sector | DWH |
| `dim_banca` | Dimensión | banca | `cod_banca` | Corporativa, Institucional, Empresa, Inmobiliaria | DWH |
| `dim_analista` | Dimensión | analista | `cod_analista` | nombre, equipo | Base local |
| `dim_fecha` | Dimensión | día | `fecha` | día, mes, año, día hábil | Generada |
| `fact_propuesta` | Hecho | propuesta | `id_propuesta` | cliente, banca, analista, fecha de ingreso y resolución, estado, monto solicitado y aprobado | DWH + base local |
| `fact_propuesta_linea` | Hecho | propuesta × línea | `id_propuesta`, `id_linea` | tipo de línea, monto, plazo, vencimiento, indicador de renovación | DWH + archivo de renovaciones |
| `fact_garantia` | Hecho | propuesta × garantía | `id_propuesta`, `id_garantia` | tipo, valor comercial, valor de realización, cobertura | DWH |
| `fact_consulta` | Hecho | consulta de una propuesta | `id_propuesta`, `nro_consulta` | ronda, fecha y texto de la pregunta, fecha y texto de la respuesta, estado | Archivo de consultas |
| `fact_rating_cliente` | Foto diaria | cliente × fecha de corte | `cod_cliente`, `fecha_corte` | rating, modelo de rating | Archivo de rating |
| `fact_riesgo_cliente` | Foto diaria | cliente × fecha de corte | `cod_cliente`, `fecha_corte` | deuda directa e indirecta, clasificación, líneas utilizadas | DWH |
| `fact_riesgo_grupo` | Foto diaria | grupo × fecha de corte | `cod_grupo_economico`, `fecha_corte` | exposición total del grupo, límite | DWH |

Tablas de control (esquema `ctl`):
- `fuente_config`: una fila por archivo o tabla de base de datos. Para los archivos guarda el patrón, el formato, el separador, la hoja, el encabezado y las columnas esperadas. Para las tablas guarda la base y la tabla de origen, el modo `COMPLETA` o `INCREMENTAL` y la columna de marca de agua. Ambos guardan la tabla destino.
- `archivo_cargado`: archivo, fecha de corte, hash, filas y estado (`CARGADO`, `REEMPLAZADO`, `ERROR` o `NO_RECONOCIDO`). Un índice único garantiza una sola carga vigente por tipo de archivo y fecha.
- `log_ejecucion`: inicio, fin y resultado de cada corrida.
- `log_paso`: detalle de cada corrida (cada tabla extraída y la ingesta de archivos, con sus filas y su estado).
- `resultado_calidad`: regla, tabla y filas que fallan.

La marca de agua de las tablas incrementales es el máximo ya cargado en la tabla raw, así que no se guarda aparte.

El rating de la propuesta se obtiene uniendo `fact_propuesta` con `fact_rating_cliente` en la última `fecha_corte` menor o igual a la fecha de evaluación.

Detalles de la implementación:
- **Staging por fecha de corte.** Los archivos se procesan en `stg` por fecha de corte. Una fecha queda pendiente cuando su carga vigente en `ctl.archivo_cargado` todavía no está en `stg`. Las tablas que vienen de las bases se reconstruyen con la última versión de cada llave.
- **Reglas de limpieza.** Son funciones T-SQL: `stg.fn_fecha` (acepta `aaaa-mm-dd` y `dd/mm/aaaa`), `stg.fn_decimal` (coma decimal), `stg.fn_cod_cliente` (texto de 8 posiciones con ceros a la izquierda) y `stg.fn_si_no`. Una fila repetida en el mismo archivo se descarta y se conserva la primera.
- **Datos de la base local en `fact_propuesta`.** La tabla guarda también la fecha de asignación y la prioridad.
- **Origen de cada consulta en `fact_consulta`.** La tabla guarda el primer y el último archivo en que apareció cada consulta. La historia diaria de las consultas queda en `stg.consultas_propuesta`.
- **Estado a cualquier fecha.** `dwh.fn_propuesta_360(@fecha)` reconstruye la vista 360 tal como se veía en esa fecha: estado, consultas pendientes, y el rating y los riesgos vigentes. `vw_propuesta_360` es la misma función sin límite de fecha. Las líneas y las garantías vienen del DWH sin historia, así que muestran su valor actual.
- **Vistas de detalle y seguimiento.** `vw_propuesta_lineas`, `vw_propuesta_garantias` y `vw_propuesta_consultas` dan el detalle de cada propuesta. `vw_seguimiento_analista` y `vw_seguimiento_diario` sirven para el seguimiento del área.
- **Consultas que ya no aparecen.** `fact_consulta` borra las consultas que ya no figuran en ningún archivo, por ejemplo una fila errónea corregida al recargar el archivo.

Calidad y orquestación:
- **Reglas de archivos (`calidad/validaciones.py`).** Necesitan el calendario y la carpeta: `ARCHIVO_FALTANTE` (una fila por día faltante), `ARCHIVO_VACIO`, `ARCHIVO_CON_ERROR` y `ARCHIVO_NO_RECONOCIDO`.
- **Reglas de datos (`ctl.sp_reglas_calidad`, en SQL y cerca de los datos).** Son `DUPLICADO_EN_ARCHIVO`, `LLAVE_INVALIDA`, `VALOR_NO_INTERPRETABLE`, `HUERFANO` (llaves que no cruzan entre fuentes), `MONTO_DISTINTO_DWH`, `CONSULTA_INCONSISTENTE`, `PROPUESTA_SIN_ANALISTA` y `PROPUESTA_SIN_RATING`.
- **Severidad.** `ERROR` significa que el dato se pierde (la fila no llega a stg). `ALERTA` significa que el dato llega, pero hay que revisarlo.
- **Una fila por regla.** Cada regla deja una fila en `ctl.resultado_calidad` aunque no falle nada. `ctl.vw_calidad_ultima_ejecucion` es el reporte de la última corrida.
- **Calidad y estado de la corrida.** La calidad no cambia el estado técnico de la corrida (`OK` o `CON ERRORES`) ni el código de salida, que solo reflejan fallas técnicas. El resumen de calidad queda en `ctl.log_ejecucion.mensaje`.
- **Modos de ejecución.** El modo diario procesa lo nuevo o cambiado. `--fecha ddmmaaaa` reprocesa esa fecha de punta a punta: recarga sus archivos aunque no hayan cambiado y limita las reglas de archivos a esa fecha.
- **Reintentos.** Las extracciones y los procedimientos se reintentan ante fallas pasajeras de SQL Server (conexión, deadlock, tiempo de espera), según `settings.yaml > orquestacion`. Un error de datos no se reintenta.

## 6. Estructura del proyecto demo

El demo reproduce el caso con datos sintéticos: dos bases simuladas (DWH y base local), una carpeta que imita la ruta compartida con 30 días de archivos, y el pipeline completo hasta el buscador 360.

### Árbol de carpetas

```text
arc-integracion-datos/
├── README.md                     # Caso, arquitectura y cómo ejecutar
├── requirements.txt              # pandas, openpyxl, pyodbc, sqlalchemy, pyyaml, streamlit, pytest
├── .env.example                  # Servidor, usuario y clave de SQL Server
├── docker-compose.yml            # SQL Server 2022 Developer (opcional si ya tienes uno local)
├── config/
│   ├── settings.yaml             # Conexiones, ruta de archivos, días a procesar
│   └── fuentes.yaml              # Por tipo de archivo: patrón, formato, separador, hoja, tabla destino
├── data/
│   └── ruta_compartida/          # Simula la carpeta de red
│       ├── consultas_propuesta_01112026.csv
│       ├── rating_cliente_01112026.xlsx
│       ├── renovacion_lineas_01112026.txt
│       └── ...                   # Un juego de archivos por día
├── sql/
│   ├── 00_crear_bases_y_esquemas.sql   # DWH_CORP_SIM, BD_ARC_LOCAL, ARC_INTEGRADO (raw, stg, dwh, ctl)
│   ├── 01_ctl_tablas_control.sql       # fuente_config, archivo_cargado, log_ejecucion, log_paso, resultado_calidad
│   ├── 02_fuentes_simuladas.sql        # Tablas de origen del DWH y de la base local
│   ├── 03_raw_tablas.sql
│   ├── 04_stg_procedimientos.sql       # Limpieza, tipos, llaves, deduplicación
│   ├── 05_dwh_modelo.sql               # Dimensiones y hechos
│   ├── 06_dwh_carga.sql                # MERGE de stg a dwh por fecha de corte
│   ├── 07_vistas_consumo.sql           # fn_propuesta_360(@fecha), vw_propuesta_360, detalle y seguimiento
│   └── 08_reglas_calidad.sql
├── src/
│   ├── config.py                 # Lee settings.yaml, fuentes.yaml y .env
│   ├── db.py                     # Conexión y ejecución de scripts SQL
│   ├── generar_datos.py          # Crea clientes, propuestas y archivos diarios sintéticos
│   ├── ingesta/
│   │   ├── descubrir_archivos.py # Regex nombre_ddmmaaaa, fecha de corte, hash
│   │   ├── lector_archivos.py    # CSV, Excel y TXT a DataFrame → tablas raw
│   │   └── extractor_bd.py       # Carga incremental desde DWH y base local
│   ├── calidad/
│   │   └── validaciones.py       # Nulos en llaves, duplicados, archivo faltante, filas = 0
│   ├── control/
│   │   ├── auditoria.py          # Escribe en ctl.archivo_cargado, ctl.log_ejecucion y ctl.log_paso
│   │   └── fuente_config.py      # Sincroniza config/fuentes.yaml con ctl.fuente_config
│   └── run_pipeline.py           # Orquesta: ingesta → stg → dwh → calidad
├── app/
│   └── buscador_360.py           # Streamlit: busca por propuesta, cliente o grupo
├── powerbi/
│   └── seguimiento_propuestas.pbix
├── docs/
│   ├── caso_y_problematica.md
│   ├── arquitectura.md
│   └── diccionario_datos.md
└── tests/
    ├── test_descubrir_archivos.py
    ├── test_lector_archivos.py
    ├── test_validaciones.py
    └── test_buscador_360.py
```

### Archivos simulados de la ruta compartida

| Archivo | Formato | Columnas | Problemas sembrados a propósito |
| --- | --- | --- | --- |
| `consultas_propuesta_ddmmaaaa` | CSV con `;` | id\_propuesta, nro\_consulta, ronda, fecha\_pregunta, pregunta, fecha\_respuesta, respuesta, estado | Fechas en `dd/mm/aaaa` y `aaaa-mm-dd`, filas repetidas |
| `rating_cliente_ddmmaaaa` | Excel (.xlsx) | cod\_cliente, rating, modelo\_rating, fecha\_rating | Código de cliente como número (pierde ceros a la izquierda), filas de título antes del encabezado |
| `renovacion_lineas_ddmmaaaa` | Texto plano con `\|` | id\_propuesta, id\_linea, tipo\_linea, monto, plazo\_meses, fecha\_vencimiento, es\_renovacion | Montos con coma decimal, un día faltante |

### Ejecución del demo

1. Levantar SQL Server: `docker compose up -d` (o usar una instancia local).
2. Instalar dependencias: `pip install -r requirements.txt` y copiar `.env.example` a `.env`.
3. Crear bases, esquemas y fuentes simuladas: `python src/run_pipeline.py --init`.
4. Generar 30 días de datos: `python src/generar_datos.py --dias 30`.
5. Correr el pipeline completo o un día: `python src/run_pipeline.py` o `python src/run_pipeline.py --fecha 01112026`.
6. Revisar auditoría y calidad: `SELECT * FROM ctl.archivo_cargado` y `ctl.resultado_calidad`.
7. Abrir el buscador: `streamlit run app/buscador_360.py`.

Para la demostración en clase, se cronometra la búsqueda de una propuesta en la carpeta (abriendo archivos) frente a la misma búsqueda en el buscador 360.

## 7. Plan de implementación del demo

El demo se construye en cinco fases, cada una con un entregable que ya se puede mostrar.

1. **Fuentes simuladas.** Script `generar_datos.py`, bases `DWH_CORP_SIM` y `BD_ARC_LOCAL` con datos de ejemplo y 30 días de archivos en `ruta_compartida`, con los problemas sembrados.
   - Entregable: el “antes” del caso, listo para mostrar el desorden.
2. **Ingesta y control.** `descubrir_archivos.py`, `lector_archivos.py`, `extractor_bd.py` y las tablas `ctl`.
   - Entregable: todas las fuentes cargadas en `raw`, con cada archivo registrado y sin cargas duplicadas.
3. **Staging y modelo integrado.** Procedimientos de limpieza en `stg`, dimensiones y hechos en `dwh`, carga por fecha de corte.
   - Entregable: `vw_propuesta_360` devolviendo propuesta, líneas, garantías, consultas, rating y riesgos en una consulta.
4. **Calidad y orquestación.** Reglas de `validaciones.py`, `run_pipeline.py` con modo diario y reproceso de una fecha.
   - Entregable: corrida diaria de punta a punta con reporte de calidad.
5. **Consumo y documentación.** Buscador 360 en Streamlit, tablero en Power BI, diccionario de datos y README.
   - Entregable: demostración del “después” con la medición del tiempo de búsqueda.

En un despliegue real, el mismo diseño se lleva a SSIS o Data Factory para la ingesta y a SQL Server Agent para la programación diaria, sin cambiar los esquemas.
