-- 07 · Consumo: vista 360 de la propuesta y vistas de detalle y seguimiento
--
-- dwh.fn_propuesta_360(@fecha) reconstruye cómo se veía cada propuesta en una fecha:
--   - solo propuestas ingresadas hasta @fecha; estado EN EVALUACION si se resolvió después
--   - consultas hechas hasta la fecha de evaluación y cuántas seguían sin respuesta
--   - rating y riesgos de la última foto (fecha_corte) <= fecha de evaluación
--   fecha de evaluación = fecha de resolución si ya se resolvió; si no, @fecha.
--   Líneas y garantías vienen del DWH sin historia: se muestran con su valor actual.
-- dwh.vw_propuesta_360 = la función sin límite de fecha (estado actual).

USE ARC_INTEGRADO;
GO

CREATE OR ALTER FUNCTION dwh.fn_propuesta_360 (@fecha DATE)
RETURNS TABLE
AS
RETURN
WITH ref AS (SELECT ISNULL(@fecha, CONVERT(DATE, '99991231')) AS f)
SELECT
    -- Propuesta
    p.id_propuesta, p.tipo_propuesta, p.fecha_ingreso, p.fecha_asignacion,
    CASE WHEN p.fecha_resolucion <= r.f THEN p.fecha_resolucion END             AS fecha_resolucion,
    CASE WHEN p.fecha_resolucion <= r.f THEN p.estado ELSE 'EN EVALUACION' END  AS estado,
    NULLIF(e.f_eval, CONVERT(DATE, '99991231'))                                  AS fecha_evaluacion,
    DATEDIFF(DAY, p.fecha_ingreso, CASE WHEN e.f_eval = '99991231' THEN CAST(SYSDATETIME() AS DATE)
                                        ELSE e.f_eval END)                       AS dias_en_area,
    p.prioridad, p.moneda, p.monto_solicitado,
    CASE WHEN p.fecha_resolucion <= r.f THEN p.monto_aprobado END               AS monto_aprobado,
    -- Cliente, grupo, banca y analista
    p.cod_cliente, c.razon_social, c.ruc, c.segmento, p.cod_banca, b.nombre_banca,
    c.cod_grupo_economico, g.nombre_grupo, g.sector,
    p.cod_analista, an.nombre AS analista, an.equipo,
    -- Líneas
    ISNULL(l.n_lineas, 0) AS n_lineas, l.monto_lineas, l.n_lineas_renovacion, l.proximo_vencimiento,
    -- Garantías
    ISNULL(ga.n_garantias, 0) AS n_garantias, ga.valor_comercial_total, ga.valor_realizacion_total,
    CAST(ga.valor_realizacion_total * 100.0 / NULLIF(p.monto_solicitado, 0) AS DECIMAL(9,2)) AS cobertura_pct,
    -- Consultas
    ISNULL(q.n_consultas, 0) AS n_consultas, ISNULL(q.n_consultas_pendientes, 0) AS n_consultas_pendientes,
    q.n_rondas, q.fecha_ultima_pregunta,
    -- Rating a la fecha de evaluación
    rt.rating, rt.modelo_rating, rt.fecha_rating, rt.fecha_corte AS fecha_corte_rating,
    -- Riesgo del cliente a la fecha de evaluación (PEN)
    rc.deuda_directa, rc.deuda_indirecta, rc.clasificacion, rc.lineas_utilizadas,
    rc.fecha_corte AS fecha_corte_riesgo,
    -- Riesgo del grupo a la fecha de evaluación (PEN)
    rg.exposicion_total AS exposicion_grupo, rg.limite_grupo, rg.pct_uso_limite AS pct_uso_limite_grupo
FROM dwh.fact_propuesta p
CROSS JOIN ref r
CROSS APPLY (SELECT CASE WHEN p.fecha_resolucion <= r.f THEN p.fecha_resolucion ELSE r.f END AS f_eval) e
LEFT JOIN dwh.dim_cliente c          ON c.cod_cliente = p.cod_cliente
LEFT JOIN dwh.dim_banca b            ON b.cod_banca = p.cod_banca
LEFT JOIN dwh.dim_grupo_economico g  ON g.cod_grupo_economico = c.cod_grupo_economico
LEFT JOIN dwh.dim_analista an        ON an.cod_analista = p.cod_analista
OUTER APPLY (
    SELECT COUNT(*) AS n_lineas, SUM(x.monto) AS monto_lineas,
           SUM(CASE WHEN x.es_renovacion = 1 THEN 1 ELSE 0 END) AS n_lineas_renovacion,
           MIN(x.fecha_vencimiento) AS proximo_vencimiento
    FROM dwh.fact_propuesta_linea x WHERE x.id_propuesta = p.id_propuesta) l
OUTER APPLY (
    SELECT COUNT(*) AS n_garantias, SUM(x.valor_comercial) AS valor_comercial_total,
           SUM(x.valor_realizacion) AS valor_realizacion_total
    FROM dwh.fact_garantia x WHERE x.id_propuesta = p.id_propuesta) ga
OUTER APPLY (
    SELECT COUNT(*) AS n_consultas, SUM(y.pendiente) AS n_consultas_pendientes,
           MAX(y.ronda) AS n_rondas, MAX(y.fecha_pregunta) AS fecha_ultima_pregunta
    FROM (SELECT x.ronda, x.fecha_pregunta,
                 -- sin respuesta a la fecha de evaluación
                 CASE WHEN x.fecha_respuesta IS NULL OR x.fecha_respuesta > e.f_eval THEN 1 ELSE 0 END AS pendiente
          FROM dwh.fact_consulta x
          WHERE x.id_propuesta = p.id_propuesta AND x.fecha_pregunta <= e.f_eval) y) q
OUTER APPLY (
    SELECT TOP 1 x.rating, x.modelo_rating, x.fecha_rating, x.fecha_corte
    FROM dwh.fact_rating_cliente x
    WHERE x.cod_cliente = p.cod_cliente AND x.fecha_corte <= e.f_eval
    ORDER BY x.fecha_corte DESC) rt
OUTER APPLY (
    SELECT TOP 1 x.deuda_directa, x.deuda_indirecta, x.clasificacion, x.lineas_utilizadas, x.fecha_corte
    FROM dwh.fact_riesgo_cliente x
    WHERE x.cod_cliente = p.cod_cliente AND x.fecha_corte <= e.f_eval
    ORDER BY x.fecha_corte DESC) rc
OUTER APPLY (
    SELECT TOP 1 x.exposicion_total, x.limite_grupo, x.pct_uso_limite
    FROM dwh.fact_riesgo_grupo x
    WHERE x.cod_grupo_economico = c.cod_grupo_economico AND x.fecha_corte <= e.f_eval
    ORDER BY x.fecha_corte DESC) rg
WHERE p.fecha_ingreso <= r.f;
GO

CREATE OR ALTER VIEW dwh.vw_propuesta_360
AS
SELECT * FROM dwh.fn_propuesta_360(NULL);
GO

------------------------------------------------------------------------
-- Detalle para el buscador
------------------------------------------------------------------------
CREATE OR ALTER VIEW dwh.vw_propuesta_lineas
AS
SELECT l.id_propuesta, p.cod_cliente, c.razon_social, l.id_linea, l.tipo_linea, l.moneda, l.monto,
       l.plazo_meses, l.fecha_vencimiento,
       CASE l.es_renovacion WHEN 1 THEN 'SI' WHEN 0 THEN 'NO' ELSE 'SIN DATO' END AS renovacion,
       l.fecha_corte_renovacion
FROM dwh.fact_propuesta_linea l
JOIN dwh.fact_propuesta p ON p.id_propuesta = l.id_propuesta
LEFT JOIN dwh.dim_cliente c ON c.cod_cliente = p.cod_cliente;
GO

CREATE OR ALTER VIEW dwh.vw_propuesta_garantias
AS
SELECT g.id_propuesta, p.cod_cliente, c.razon_social, g.id_garantia, g.tipo_garantia, g.moneda,
       g.valor_comercial, g.valor_realizacion, g.cobertura_pct
FROM dwh.fact_garantia g
JOIN dwh.fact_propuesta p ON p.id_propuesta = g.id_propuesta
LEFT JOIN dwh.dim_cliente c ON c.cod_cliente = p.cod_cliente;
GO

CREATE OR ALTER VIEW dwh.vw_propuesta_consultas
AS
SELECT q.id_propuesta, p.cod_cliente, c.razon_social, q.ronda, q.nro_consulta,
       q.fecha_pregunta, q.pregunta, q.fecha_respuesta, q.respuesta, q.estado, q.dias_respuesta,
       q.fecha_corte_primera, q.fecha_corte_ultima
FROM dwh.fact_consulta q
LEFT JOIN dwh.fact_propuesta p ON p.id_propuesta = q.id_propuesta
LEFT JOIN dwh.dim_cliente c ON c.cod_cliente = p.cod_cliente;
GO

------------------------------------------------------------------------
-- Seguimiento del área
------------------------------------------------------------------------
-- Carga de trabajo y tiempos por analista
CREATE OR ALTER VIEW dwh.vw_seguimiento_analista
AS
SELECT an.cod_analista, an.nombre, an.equipo,
       SUM(CASE WHEN p.fecha_resolucion IS NULL THEN 1 ELSE 0 END)     AS propuestas_en_evaluacion,
       SUM(CASE WHEN p.fecha_resolucion IS NOT NULL THEN 1 ELSE 0 END) AS propuestas_resueltas,
       SUM(CASE WHEN p.estado = 'APROBADA' THEN 1 ELSE 0 END)          AS aprobadas,
       SUM(CASE WHEN p.estado = 'OBSERVADA' THEN 1 ELSE 0 END)         AS observadas,
       SUM(CASE WHEN p.estado = 'DENEGADA' THEN 1 ELSE 0 END)          AS denegadas,
       CAST(AVG(CAST(p.dias_evaluacion AS DECIMAL(9,2))) AS DECIMAL(9,1)) AS dias_promedio_evaluacion,
       SUM(ISNULL(q.pendientes, 0))                                    AS consultas_pendientes
FROM dwh.dim_analista an
LEFT JOIN dwh.fact_propuesta p ON p.cod_analista = an.cod_analista
OUTER APPLY (SELECT COUNT(*) AS pendientes FROM dwh.fact_consulta x
             WHERE x.id_propuesta = p.id_propuesta AND x.fecha_respuesta IS NULL) q
GROUP BY an.cod_analista, an.nombre, an.equipo;
GO

-- Propuestas ingresadas y resueltas por día y banca
CREATE OR ALTER VIEW dwh.vw_seguimiento_diario
AS
SELECT f.fecha, f.nombre_dia, f.es_dia_habil, b.cod_banca, b.nombre_banca,
       (SELECT COUNT(*) FROM dwh.fact_propuesta p WHERE p.fecha_ingreso = f.fecha AND p.cod_banca = b.cod_banca)    AS ingresadas,
       (SELECT COUNT(*) FROM dwh.fact_propuesta p WHERE p.fecha_resolucion = f.fecha AND p.cod_banca = b.cod_banca) AS resueltas
FROM dwh.dim_fecha f
CROSS JOIN dwh.dim_banca b
WHERE f.fecha BETWEEN (SELECT MIN(fecha_ingreso) FROM dwh.fact_propuesta)
                  AND (SELECT MAX(fecha_corte) FROM dwh.fact_riesgo_cliente);
GO
