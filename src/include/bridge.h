#include <stdint.h>
#include "duckdb.h"

typedef uint64_t idx_t;

void duckdb_data_chunk_set_value(duckdb_data_chunk chunk, idx_t col_idx, idx_t index, duckdb_value value);