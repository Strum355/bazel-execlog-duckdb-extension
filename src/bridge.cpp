#define DUCKDB_EXTENSION_MAIN

#include "include/bridge.hpp"

#include "duckdb.hpp"

extern "C" {
	// implemented in zig
	void compact_execlog_init_zig(void *db);

	// implemented in zig
	const char *compact_execlog_version_zig(void);

	// called by duckdb cli using the convention {extension_name}_init(db)
	DUCKDB_EXTENSION_API void compact_execlog_init(duckdb::DatabaseInstance &db) {
		compact_execlog_init_zig((void *)&db);
	}

	// called by duckdb cli using the convention {compact_execlog_name}_version()
	DUCKDB_EXTENSION_API const char *compact_execlog_version() {
		return compact_execlog_version_zig();
	}
};

#ifndef DUCKDB_EXTENSION_MAIN
#error DUCKDB_EXTENSION_MAIN not defined
#endif

void duckdb::CompactExeclogExtension::Load(DuckDB &db) {
	DuckDB *ptr = &db;
	compact_execlog_init_zig((void *)ptr);
}

std::string duckdb::CompactExeclogExtension::Name() {
	return "compact_execlog";
}