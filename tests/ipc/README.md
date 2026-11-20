# Arrow IPC streams for `package/IpcTest.roc`

## Streams of a real server

These files are answers of a Feldera 0.382.0 pipeline to ad-hoc queries with
`format=arrow_ipc` (arrow-rs 59, DataFusion's `StreamWriter`, no compression):

| File | Query | Content |
|---|---|---|
| `probe3.arrow` | `SELECT * FROM probe ORDER BY id LIMIT 3` | 15 columns: BIGINT, INTEGER, TINYINT, DOUBLE, DECIMAL(10,2), VARCHAR, BOOLEAN, TIMESTAMP, DATE, TIME, VARCHAR ARRAY, MAP<VARCHAR, INTEGER>, VARBINARY, VARIANT (all null), ROW(a INTEGER, b VARCHAR); 3 rows |
| `sums.arrow` | an aggregate view with `NULL AS nothing` and `COUNT(*) OVER ()` | DECIMAL(38,2), a Null column |
| `empty.arrow` | `SELECT * FROM probe WHERE id < 0` | the schema and the end marker, no batch |

    curl -s --get "$HOST/v0/pipelines/$PIPELINE/query" --data-urlencode "sql=..." --data-urlencode "format=arrow_ipc" -o file.arrow

## Crafted streams

`make_fixtures.py` writes these files: a small Arrow IPC writer in Python,
standard library only, with no Arrow library. Its output is the same on
every run.

    python3 tests/ipc/make_fixtures.py

Valid streams that the server does not send:

| File | Content |
|---|---|
| `zero_columns.arrow` | a schema of no fields and a batch of 5 rows |
| `zero_rows.arrow` | `id` Int64, `name` Utf8, and a batch of 0 rows |
| `v4.arrow` | metadata version V4 with the continuation marker: `id` Int64, rows 7 and 8 |
| `depth64.arrow` | a schema only: one column of lists nested 64 fields deep, the limit |

Streams that the reader must refuse:

| File | Content | Error |
|---|---|---|
| `depth65.arrow` | lists nested 65 fields deep | `InvalidIpc`: deeper than 64 levels |
| `fan_out.arrow` | 10 levels of structs; the 10 children of each are one shared table, so 1 KB names 10^10 fields | `InvalidIpc`: more than 100000 fields |
| `shared_text.arrow` | a field whose 200 metadata entries are one shared pair with a key of 100 bytes | `InvalidIpc`: text larger than 4 times the message |
| `long_vector.arrow` | the schema's vector of fields says 0xFFFFFFFF elements | `InvalidIpc`: the vector lies outside the metadata |
| `long_buffers.arrow` | a Utf8View column; the batch's vector of buffers says 0xFFFFFFFF elements, and the column 0xFFFFFFFE data buffers | `InvalidIpc`: the vector lies outside the metadata |
| `extra_node.arrow` | a batch with a field node that no column uses | `InvalidIpc` |
| `extra_buffer.arrow` | a batch with a buffer that no column uses | `InvalidIpc` |
| `short_column.arrow` | a batch of 3 rows whose column has 2 | `InvalidIpc`: the column and both counts |
| `bad_offsets.arrow` | a Utf8 column `name` whose offsets decrease | `InvalidIpc`: the batch and the column |
| `time_unit.arrow` | a Timestamp field `ts` with time unit 7 | `InvalidIpc`: the unit and the field |
| `type_id.arrow` | a field `x` with type id 30 | `InvalidIpc`: the id and the field |
| `old_version.arrow` | a schema, then a batch message of metadata version V3 that says 1000 bytes of body and has none | `Unsupported`, with no wait for the body |
