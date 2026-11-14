-- 00 · Bases de datos y esquemas del demo
-- DWH_CORP_SIM : simula el datawarehouse corporativo
-- BD_ARC_LOCAL : simula la base local del área (SQL Server)
-- ARC_INTEGRADO: almacén integrado con zonas raw, stg, dwh y control ctl
-- Idempotente: se puede ejecutar varias veces.

IF DB_ID('DWH_CORP_SIM') IS NULL CREATE DATABASE DWH_CORP_SIM;
GO
IF DB_ID('BD_ARC_LOCAL') IS NULL CREATE DATABASE BD_ARC_LOCAL;
GO
IF DB_ID('ARC_INTEGRADO') IS NULL CREATE DATABASE ARC_INTEGRADO;
GO

USE ARC_INTEGRADO;
GO
IF SCHEMA_ID('raw') IS NULL EXEC('CREATE SCHEMA raw');
GO
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
GO
IF SCHEMA_ID('dwh') IS NULL EXEC('CREATE SCHEMA dwh');
GO
IF SCHEMA_ID('ctl') IS NULL EXEC('CREATE SCHEMA ctl');
GO
