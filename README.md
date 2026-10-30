# Babel Fish — base de datos

Repositorio de esquema. **No es un proyecto Node**: no hay `package.json`, ni ORM, ni generador de
migraciones. La fuente de verdad del esquema son los archivos SQL escritos a mano de `sql/`
(DEC-005/006).

Remoto: [CarlosGarciaRa/babel-fish-db](https://github.com/CarlosGarciaRa/babel-fish-db).
Las ramas `main` y `staging` sirven para control de versiones. Por decisión de Carlos del
2026-10-30, ningún push ni merge en este repositorio despliega a Railway o aplica scripts
contra una base alojada. La aplicación de SQL sigue siendo un paso manual explícito sobre
la base seleccionada. El despliegue de la API tampoco aplica SQL automáticamente.

## Estructura

```
sql/     Scripts versionados de cambio de esquema (NNNN_descripcion.sql)
bin/     Aplicador y verificador independientes del ORM
```

El backend declara `src/database/schema.ts` (Drizzle) únicamente como **espejo** del esquema para
consultar y escribir registros. Nunca genera ni aplica DDL.

## Procedimiento

1. Escribir el siguiente archivo `NNNN_descripcion.sql`, con número de cuatro cifras y orden
   posterior a los ya aplicados.
2. Revisar el SQL, especialmente la preservación de registros existentes. Para añadir columnas se
   usa `ALTER TABLE`, con backfill y restricciones por etapas cuando corresponda.
3. Probarlo en una base aislada con datos representativos.
4. Elegir explícitamente la base mediante `DATABASE_URL` y ejecutar `bin/apply.sh`.
5. Verificar con `bin/verify.sh` que no quedan pendientes y que los checksums coinciden.

```sh
DATABASE_URL=postgresql://babel_fish:change-me@127.0.0.1:5432/babel_fish bin/apply.sh
DATABASE_URL=postgresql://babel_fish:change-me@127.0.0.1:5432/babel_fish bin/verify.sh
```

Desde el backend, `npm run db:apply` invoca el mismo aplicador.

## Reglas del aplicador

- Lee solo archivos que cumplan `^\d{4}_[a-z0-9_]+\.sql$`, en orden lexicográfico.
- Calcula SHA-256 de cada archivo y guarda nombre, checksum y fecha en `public.schema_changes`.
- Un archivo ya aplicado **no se modifica, elimina ni renumera**. Una corrección se expresa en un
  archivo nuevo. Si el checksum registrado no coincide, el aplicador falla.
- Se rechaza insertar un script anterior al último aplicado.
- Todos los pendientes y sus registros se aplican en **una sola transacción**; un fallo revierte el
  lote completo.
- Un advisory lock transaccional impide dos aplicaciones concurrentes.
- Repetir la ejecución sin pendientes no cambia nada.

Los scripts no deben contener `BEGIN`, `COMMIT`, `ROLLBACK`, `CREATE DATABASE` ni `VACUUM`: el
aplicador ya envuelve el lote en una transacción.

## Pruebas

```sh
bash test/apply.test.sh
```

Levanta un PostgreSQL desechable en Docker, aplica el esquema y comprueba: aplicación inicial,
repetición sin cambios, rechazo de un archivo ya aplicado modificado, rollback de un lote fallido,
rechazo de scripts fuera de orden, concurrencia y preservación de filas entre `0001` y `0002`.
Nunca usa el `DATABASE_URL` configurado por el usuario.

## Límites

El aplicador no hace copias de seguridad ni decide cómo revertir cambios ya confirmados. Para una
base con datos que deban conservarse, preparar respaldo y recuperación antes de aplicar SQL.

Las credenciales y los roles del despliegue definitivo siguen pendientes.
