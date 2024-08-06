#pragma once

#include "duckdb.hpp"

extern "C" {
	DUCKDB_EXTENSION_API char const *compact_execlog_version();
	DUCKDB_EXTENSION_API void compact_execlog_init(duckdb::DatabaseInstance &db);
}

namespace duckdb {
	class CompactExeclogExtension : public Extension {
	public:
		void Load(DuckDB &db) override;
		std::string Name() override;
	};
}