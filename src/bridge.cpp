#include "duckdb.hpp"
#include "duckdb.h"
#include "duckdb/common/types/data_chunk.hpp"
#include "duckdb/common/types/value.hpp"

typedef uint64_t idx_t;

extern "C" {
	void duckdb_data_chunk_set_value(duckdb_data_chunk chunk, idx_t col_idx, idx_t index, duckdb_value value) {
		auto dchunk = reinterpret_cast<duckdb::DataChunk *>(chunk);
		auto dvalue = reinterpret_cast<duckdb::Value&>(value);
		dchunk->SetValue(col_idx, index, dvalue);
	}
};