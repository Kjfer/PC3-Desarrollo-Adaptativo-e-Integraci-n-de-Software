# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Phases 1–4 are implemented:
- Phase 1, simulated sources: `sql/00`, `sql/02`, `src/generar_datos.py`.
- Phase 2, ingestion and control into `raw`: `sql/01`, `sql/03`, `config/fuentes.yaml`, `src/ingesta/`, `src/control/`.
- Phase 3, `stg` and `dwh` in T-SQL plus the 360 view: `sql/04`–`sql/07`.
- Phase 4, quality and orchestration: `sql/08`, `src/calidad/validaciones.py`, retries in `db.py`, modes in `run_pipeline.py`.

Phase 5 is in progress. The Streamlit app `app/buscador_360.py` is done. Power BI, the data dictionary and the README are pending. The design doc `docs/Proyecto de Integración de Datos – Admisión de Riesgos Corporativos.md` is the source of truth for the target structure, data model and demo plan (section 6 has the planned folder tree; section 7 has the five build phases). When code is added, follow that doc. If an implementation decision changes the design, update the doc too. Once real commands and files exist, update this file to match.

Project language is Spanish: table, column, file and module names, and docs, use Spanish (`propuesta`, `fecha_corte`, `cod_cliente`, …). Keep that convention.

## What the system does

A demo data-integration pipeline for a bank's Corporate Risk Admission area. It consolidates three sources into one SQL Server warehouse so that a credit proposal (`propuesta`) can be viewed in full from a single place:

1. **Corporate DWH** (simulated as DB `DWH_CORP_SIM`): proposals, credit lines, collateral (`garantia`), client and group risk.
2. **Area's local DB** (simulated as `BD_ARC_LOCAL`): tracking and assignment tables.
3. **Shared network folder** (simulated as `data/ruta_compartida/`): daily files named `nombre_ddmmaaaa.(csv|xlsx|txt)`. They hold proposal Q&A (`consultas_propuesta`, CSV with `;`), client rating (`rating_cliente`, xlsx) and line renewals (`renovacion_lineas`, `|`-delimited txt).

Target DB `ARC_INTEGRADO` has four schemas: `raw` → `stg` → `dwh`, plus `ctl` for control and audit.

## Architecture rules (cross-cutting)

- **ELT, not ETL.** Python only lands data into `raw`, as a faithful copy plus control columns (source file, `fecha_corte`, load timestamp). All cleaning, typing, key standardization and dedup happens in T-SQL procedures (`stg`). `MERGE` statements then load `dwh` by `fecha_corte`.
- **`fecha_corte` comes from the filename.** Use the regex `^(?P<nombre>.+)_(?P<fecha>\d{8})\.(csv|xlsx|txt)$`, where the date is `ddmmaaaa` (day first). `fecha_corte` is carried as a column through every layer.
- **Idempotent loads.** Each file is hashed and recorded in `ctl.archivo_cargado`. Skip a file that was already loaded with the same hash. If its hash changed, reload only that `fecha_corte`.
- **Metadata-driven ingestion.** Each run starts by copying `config/fuentes.yaml` into `ctl.fuente_config` (DELETE + INSERT). The pipeline then reads its config from that table, so edit the YAML, not the table. It describes file types and DB tables:
  - A file type has a pattern, format, separator, sheet, header text and expected columns.
  - A DB table has a source, a mode (`COMPLETA` truncates and reloads; `INCREMENTAL` uses a watermark) and a watermark column.

  To add a report type, add a YAML entry and its `raw` table in `sql/03`; no Python changes are needed.
- **Raw conventions.** File tables (`raw.arch_*`) hold all data columns as NVARCHAR, exactly as read. Excel ints become `"12345"` and dates become ISO text. Their control columns are `id_archivo`, `archivo_origen`, `fecha_corte`, `nro_fila` and `fecha_carga`. DB tables (`raw.dwh_*`, `raw.loc_*`) keep the source types plus `id_ejecucion` and `fecha_carga`. An incremental table's watermark is `MAX(col)` of its raw table, and its raw table accumulates versions.
- **Load states.** `ctl.archivo_cargado.estado` is one of `CARGADO`, `REEMPLAZADO`, `ERROR` or `NO_RECONOCIDO`. A filtered unique index allows only one `CARGADO` row per (`cod_fuente`, `fecha_corte`). Each file is loaded in one transaction (ctl row + DELETE of that date + raw insert). A failed file is logged as `ERROR` and doesn't stop the run. Likewise, a failed step in `Auditoria.paso()` is logged to `ctl.log_paso` and the run continues.
- **Integration keys:** `id_propuesta`, `cod_cliente` and `cod_grupo_economico`. `cod_cliente` must be normalized to fixed-length text, because the Excel source turns it into a number and drops leading zeros.
- **Daily snapshots.** `fact_rating_cliente`, `fact_riesgo_cliente` and `fact_riesgo_grupo` keep one row per key × `fecha_corte`. To get a proposal's rating, join on the latest `fecha_corte` that is ≤ the evaluation date, not the current rating.
- **stg → dwh mechanics.**
  - Every stg/dwh procedure owns its transaction and ends with `SELECT @filas AS filas`. `run_pipeline.py` calls them through `db.ejecutar_proc` (autocommit), in the order listed in `PROCS_STG` and `PROCS_DWH`. dwh is skipped if any stg step fails.
  - File-sourced stg tables are incremental by `fecha_corte`. A date is pending when its `CARGADO` row in `ctl.archivo_cargado` (by `id_archivo`) isn't in stg yet. `@reprocesar_todo = 1` redoes every date.
  - DB-sourced stg tables are rebuilt each run, keeping the latest version per key.
  - dwh loads with `MERGE` and updates only changed rows (`EXISTS (SELECT s.* EXCEPT SELECT t.*)`), so a no-change run affects 0 rows.
  - `fact_rating_cliente` limits its MERGE target to the dates that have a live file, and uses `NOT MATCHED BY SOURCE THEN DELETE`.
  - dwh tables have no physical FKs on purpose. Orphans are a quality-rule concern.
- **Consumption point** is `dwh.fn_propuesta_360(@fecha)`, which shows the state as of any date. `dwh.vw_propuesta_360` is the same function with `NULL` (current state). They return proposal, lines, collateral, Q&A, rating and risk, and feed the Streamlit app `app/buscador_360.py` and Power BI. Detail views: `vw_propuesta_lineas`, `vw_propuesta_garantias`, `vw_propuesta_consultas`, `vw_seguimiento_analista`, `vw_seguimiento_diario`.
- **Expected gaps (not bugs).** Proposals evaluated before the first daily file have no rating, and their lines have `es_renovacion = NULL`. Proposals that entered on the last simulated day have no analyst yet.
- **T-SQL gotcha.** An aggregate can't mix an outer reference with inner columns (error 8124). Compute the per-row value in a derived table inside the `APPLY` first.

## Deliberately seeded data problems

`src/generar_datos.py` is meant to create dirty data on purpose so the pipeline can show it fixing them. Don't "fix" these in the generator:
- consultas: mixed date formats (`dd/mm/aaaa` and `aaaa-mm-dd`) and duplicate rows
- rating: numeric `cod_cliente` and title rows above the header (on some days one extra row, so the header must be found by searching for `cod_cliente`, not by a fixed skiprows)
- renovaciones: decimal comma in amounts and one missing day

With the default seed, a clean daily run reports exactly 3 quality alerts, and all are expected:
- `ARCHIVO_FALTANTE` for `renovacion_lineas` on 25/10.
- `DUPLICADO_EN_ARCHIVO`: 132 duplicate query rows.
- `PROPUESTA_SIN_ANALISTA`: 2 proposals from the last day.

Anything beyond those three means something changed.

## Quality rules

All results go to `ctl.resultado_calidad`, with one row per rule × table even when 0 rows fail. `ctl.vw_calidad_ultima_ejecucion` shows the latest report.
- **File-level rules** live in `src/calidad/validaciones.py`, because they need the calendar or the folder: missing, empty, failed and unrecognized files. The pure logic (`fechas_faltantes`, `resumir`) is unit-tested.
- **Data rules** live in `sql/08` (`ctl.sp_reglas_calidad @id_ejecucion, @fecha_corte`): duplicates, invalid keys, uninterpretable values, orphans and consistency checks.
  - To add a rule, copy one `WITH f AS (...) INSERT @r ...` block. `f` must return the failing rows with an NVARCHAR `ej` column. A CHAR `ej` fails `STRING_AGG` with an `N''` separator (error 8116).
- **Severity:** `ERROR` means the row is lost before stg; `ALERTA` means the data passes but needs review.
- **Quality never changes the run's technical status or exit code.** Its summary goes to `ctl.log_ejecucion.mensaje`.

## Commands

Environment: local SQL Server instance (no Docker), Windows authentication, ODBC Driver 18 with `TrustServerCertificate=yes`. Connection settings live in `.env` (template: `.env.example`). Use the project venv `.venv`.

```bash
python -m venv .venv && .venv\Scripts\pip install -r requirements.txt   # then copy .env.example to .env
.venv\Scripts\python src/run_pipeline.py --init        # runs every sql/NN_*.sql in order (idempotent, never drops data)
.venv\Scripts\python src/generar_datos.py              # 30 days ending settings.yaml fecha_fin; reloads both simulated DBs
.venv\Scripts\python src/generar_datos.py --sin-bd     # files only; also --dias N, --fecha-fin ddmmaaaa, --semilla N
```

```bash
.venv\Scripts\python src/run_pipeline.py                         # DIARIO: new/changed files + DB -> raw -> stg -> dwh -> calidad
.venv\Scripts\python src/run_pipeline.py --fecha 01112026        # REPROCESO: force-reload that date's files, rebuild, quality scoped to it
.venv\Scripts\python src/run_pipeline.py --forzar                # daily run reloading every file (e.g. after changing an stg rule)
.venv\Scripts\python -m pytest                                   # unit tests, no DB needed (pytest.ini sets pythonpath=src app)
.venv\Scripts\python -m pytest tests/test_descubrir_archivos.py::test_no_reconocidos
```

`run_pipeline.py` exits with 1 when the run ends `CON ERRORES`. For the details, query `ctl.log_paso` and `ctl.archivo_cargado` `WHERE id_ejecucion = N`.

The generator is deterministic for a given seed. It TRUNCATEs the simulated source tables, and in `data/ruta_compartida/` it deletes only files matching its own three name patterns. If you regenerate with a different seed or dates, empty `raw` and `ctl` first, otherwise the incremental raw tables mix two datasets. Scripts run as `python src/<x>.py`, so modules inside `src/` import each other as top-level modules (`from config import ...`, `from ingesta.x import ...`).

When running DML against `ctl.archivo_cargado` with `sqlcmd`, pass `-I` (QUOTED_IDENTIFIER ON), because the table has a filtered index. pyodbc already sets it.

To check the model by hand: `SELECT * FROM dwh.vw_propuesta_360 WHERE id_propuesta = 260074`, or `SELECT * FROM dwh.fn_propuesta_360('20261025')` for the state on a past date. If an SQL script fails during `--init`, the error names the script and the batch.

Retries: `db.con_reintentos` retries only transient SQLSTATEs (`08001`, `08S01`, `40001`, `HYT00`, `HYT01`), as many times as `settings.yaml > orquestacion` allows. Wrap only idempotent work with it, such as a stg/dwh procedure or a DB extraction. File ingestion is not retried.

`--fecha` keeps files with no date in their name, so an unrecognized file is still reported in reprocess mode.

Search app: `.venv\Scripts\streamlit run app/buscador_360.py`. It is read-only and searches by proposal (id), client (code with or without leading zeros, RUC, or part of the name) or group (`GE7` → `GE0007`, or part of the name). The "Estado a una fecha" toggle passes the date to `fn_propuesta_360` and also hides Q&A asked or answered after the evaluation date. It adds `src/` to `sys.path` itself. Keep the pure logic (`interpretar_busqueda`, `consultas_a_fecha`, formatters) free of Streamlit calls, because `tests/test_buscador_360.py` imports it directly.
REGLAS CRITICAS
“Proyecto académico simulado; solo datos sintéticos.”
“Sigue la arquitectura y la estructura de carpetas de docs/Proyecto de Integración de Datos – Admisión de Riesgos Corporativos.md.”
“Windows + SQL Server local; credenciales solo en .env.”
“Explica cada cambio y no avances de fase sin mi confirmación.”

The SQL scripts in `sql/` have numeric prefixes and must run in that order (00 databases/schemas → 08 quality rules).
