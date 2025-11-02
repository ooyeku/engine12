#include "e12_orm.h"
#include "sqlite3.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Error state
static E12ORMErrorCode last_error_code = E12_ORM_OK;
static char last_error_msg[512] = {0};

static void set_error(E12ORMErrorCode code, const char* msg) {
    last_error_code = code;
    if (msg) {
        strncpy(last_error_msg, msg, sizeof(last_error_msg) - 1);
        last_error_msg[sizeof(last_error_msg) - 1] = '\0';
    } else {
        last_error_msg[0] = '\0';
    }
}

static void clear_error(void) {
    last_error_code = E12_ORM_OK;
    last_error_msg[0] = '\0';
}

// Database structure
typedef struct {
    sqlite3* db;
} E12DatabaseImpl;

// Result structure
typedef struct {
    sqlite3_stmt* stmt;
    int column_count;
    bool has_row;
    bool row_fetched;
} E12ResultImpl;

// Row structure (just a pointer to the result)
typedef struct {
    E12ResultImpl* result;
} E12RowImpl;

// Transaction structure
typedef struct {
    E12DatabaseImpl* db;
    bool committed;
    bool rolled_back;
} E12TransactionImpl;

// ============================================================================
// Database Operations
// ============================================================================

E12ORMErrorCode e12_db_open(const char* path, E12Database** out_db) {
    clear_error();
    
    if (!path || !out_db) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid arguments");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12DatabaseImpl* db_impl = (E12DatabaseImpl*)malloc(sizeof(E12DatabaseImpl));
    if (!db_impl) {
        set_error(E12_ORM_ERROR, "Memory allocation failed");
        return E12_ORM_ERROR;
    }
    
    int rc = sqlite3_open(path, &db_impl->db);
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_OPEN_FAILED, sqlite3_errmsg(db_impl->db));
        sqlite3_close(db_impl->db);
        free(db_impl);
        return E12_ORM_ERROR_OPEN_FAILED;
    }
    
    *out_db = (E12Database*)db_impl;
    return E12_ORM_OK;
}

void e12_db_close(E12Database* db) {
    if (!db) return;
    
    E12DatabaseImpl* db_impl = (E12DatabaseImpl*)db;
    if (db_impl->db) {
        sqlite3_close(db_impl->db);
    }
    free(db_impl);
}

E12ORMErrorCode e12_db_execute(E12Database* db, const char* sql, int64_t* rows_affected) {
    clear_error();
    
    if (!db || !sql) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid arguments");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12DatabaseImpl* db_impl = (E12DatabaseImpl*)db;
    
    char* err_msg = NULL;
    int rc = sqlite3_exec(db_impl->db, sql, NULL, NULL, &err_msg);
    
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_QUERY_FAILED, err_msg ? err_msg : "Query failed");
        if (err_msg) {
            sqlite3_free(err_msg);
        }
        return E12_ORM_ERROR_QUERY_FAILED;
    }
    
    if (rows_affected) {
        *rows_affected = sqlite3_changes(db_impl->db);
    }
    
    return E12_ORM_OK;
}

// ============================================================================
// Query Operations
// ============================================================================

E12ORMErrorCode e12_db_query(E12Database* db, const char* sql, E12Result** out_result) {
    clear_error();
    
    if (!db || !sql || !out_result) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid arguments");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12DatabaseImpl* db_impl = (E12DatabaseImpl*)db;
    
    sqlite3_stmt* stmt = NULL;
    int rc = sqlite3_prepare_v2(db_impl->db, sql, -1, &stmt, NULL);
    
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_QUERY_FAILED, sqlite3_errmsg(db_impl->db));
        if (stmt) {
            sqlite3_finalize(stmt);
        }
        return E12_ORM_ERROR_QUERY_FAILED;
    }
    
    E12ResultImpl* result_impl = (E12ResultImpl*)malloc(sizeof(E12ResultImpl));
    if (!result_impl) {
        set_error(E12_ORM_ERROR, "Memory allocation failed");
        sqlite3_finalize(stmt);
        return E12_ORM_ERROR;
    }
    
    result_impl->stmt = stmt;
    result_impl->column_count = sqlite3_column_count(stmt);
    result_impl->has_row = false;
    result_impl->row_fetched = false;
    
    *out_result = (E12Result*)result_impl;
    return E12_ORM_OK;
}

int e12_result_column_count(E12Result* result) {
    if (!result) return 0;
    E12ResultImpl* result_impl = (E12ResultImpl*)result;
    return result_impl->column_count;
}

const char* e12_result_column_name(E12Result* result, int col_index) {
    if (!result) return NULL;
    E12ResultImpl* result_impl = (E12ResultImpl*)result;
    if (col_index < 0 || col_index >= result_impl->column_count) {
        return NULL;
    }
    return sqlite3_column_name(result_impl->stmt, col_index);
}

bool e12_result_next_row(E12Result* result, E12Row** out_row) {
    if (!result || !out_row) return false;
    
    E12ResultImpl* result_impl = (E12ResultImpl*)result;
    
    // If we already fetched a row, step to the next one
    if (result_impl->row_fetched) {
        int rc = sqlite3_step(result_impl->stmt);
        if (rc == SQLITE_ROW) {
            result_impl->has_row = true;
        } else {
            result_impl->has_row = false;
            *out_row = NULL;
            return false;
        }
    } else {
        // First row
        int rc = sqlite3_step(result_impl->stmt);
        result_impl->row_fetched = true;
        if (rc == SQLITE_ROW) {
            result_impl->has_row = true;
        } else {
            result_impl->has_row = false;
            *out_row = NULL;
            return false;
        }
    }
    
    // Create row handle
    E12RowImpl* row_impl = (E12RowImpl*)malloc(sizeof(E12RowImpl));
    if (!row_impl) {
        result_impl->has_row = false;
        *out_row = NULL;
        return false;
    }
    
    row_impl->result = result_impl;
    *out_row = (E12Row*)row_impl;
    return true;
}

void e12_result_free(E12Result* result) {
    if (!result) return;
    
    E12ResultImpl* result_impl = (E12ResultImpl*)result;
    if (result_impl->stmt) {
        sqlite3_finalize(result_impl->stmt);
    }
    free(result_impl);
}

// ============================================================================
// Row Operations
// ============================================================================

const char* e12_row_get_text(E12Row* row, int col_index) {
    if (!row) return NULL;
    
    E12RowImpl* row_impl = (E12RowImpl*)row;
    E12ResultImpl* result_impl = row_impl->result;
    
    if (!result_impl || !result_impl->has_row) return NULL;
    if (col_index < 0 || col_index >= result_impl->column_count) return NULL;
    
    const unsigned char* text = sqlite3_column_text(result_impl->stmt, col_index);
    return (const char*)text;
}

int64_t e12_row_get_int64(E12Row* row, int col_index) {
    if (!row) return 0;
    
    E12RowImpl* row_impl = (E12RowImpl*)row;
    E12ResultImpl* result_impl = row_impl->result;
    
    if (!result_impl || !result_impl->has_row) return 0;
    if (col_index < 0 || col_index >= result_impl->column_count) return 0;
    
    return sqlite3_column_int64(result_impl->stmt, col_index);
}

double e12_row_get_double(E12Row* row, int col_index) {
    if (!row) return 0.0;
    
    E12RowImpl* row_impl = (E12RowImpl*)row;
    E12ResultImpl* result_impl = row_impl->result;
    
    if (!result_impl || !result_impl->has_row) return 0.0;
    if (col_index < 0 || col_index >= result_impl->column_count) return 0.0;
    
    return sqlite3_column_double(result_impl->stmt, col_index);
}

bool e12_row_is_null(E12Row* row, int col_index) {
    if (!row) return true;
    
    E12RowImpl* row_impl = (E12RowImpl*)row;
    E12ResultImpl* result_impl = row_impl->result;
    
    if (!result_impl || !result_impl->has_row) return true;
    if (col_index < 0 || col_index >= result_impl->column_count) return true;
    
    return sqlite3_column_type(result_impl->stmt, col_index) == SQLITE_NULL;
}

void e12_row_free(E12Row* row) {
    if (!row) return;
    
    E12RowImpl* row_impl = (E12RowImpl*)row;
    free(row_impl);
}

// ============================================================================
// Transaction Operations
// ============================================================================

E12ORMErrorCode e12_db_begin_transaction(E12Database* db, E12Transaction** out_transaction) {
    clear_error();
    
    if (!db || !out_transaction) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid arguments");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12DatabaseImpl* db_impl = (E12DatabaseImpl*)db;
    
    // Begin transaction
    char* err_msg = NULL;
    int rc = sqlite3_exec(db_impl->db, "BEGIN TRANSACTION", NULL, NULL, &err_msg);
    
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_QUERY_FAILED, err_msg ? err_msg : "Failed to begin transaction");
        if (err_msg) {
            sqlite3_free(err_msg);
        }
        return E12_ORM_ERROR_QUERY_FAILED;
    }
    
    // Create transaction handle
    E12TransactionImpl* trans_impl = (E12TransactionImpl*)malloc(sizeof(E12TransactionImpl));
    if (!trans_impl) {
        sqlite3_exec(db_impl->db, "ROLLBACK", NULL, NULL, NULL);
        set_error(E12_ORM_ERROR, "Memory allocation failed");
        return E12_ORM_ERROR;
    }
    
    trans_impl->db = db_impl;
    trans_impl->committed = false;
    trans_impl->rolled_back = false;
    
    *out_transaction = (E12Transaction*)trans_impl;
    return E12_ORM_OK;
}

E12ORMErrorCode e12_db_commit(E12Transaction* transaction) {
    clear_error();
    
    if (!transaction) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid transaction");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12TransactionImpl* trans_impl = (E12TransactionImpl*)transaction;
    
    if (trans_impl->committed || trans_impl->rolled_back) {
        set_error(E12_ORM_ERROR, "Transaction already completed");
        return E12_ORM_ERROR;
    }
    
    char* err_msg = NULL;
    int rc = sqlite3_exec(trans_impl->db->db, "COMMIT", NULL, NULL, &err_msg);
    
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_QUERY_FAILED, err_msg ? err_msg : "Failed to commit transaction");
        if (err_msg) {
            sqlite3_free(err_msg);
        }
        return E12_ORM_ERROR_QUERY_FAILED;
    }
    
    trans_impl->committed = true;
    return E12_ORM_OK;
}

E12ORMErrorCode e12_db_rollback(E12Transaction* transaction) {
    clear_error();
    
    if (!transaction) {
        set_error(E12_ORM_ERROR_INVALID_ARGUMENT, "Invalid transaction");
        return E12_ORM_ERROR_INVALID_ARGUMENT;
    }
    
    E12TransactionImpl* trans_impl = (E12TransactionImpl*)transaction;
    
    if (trans_impl->committed || trans_impl->rolled_back) {
        set_error(E12_ORM_ERROR, "Transaction already completed");
        return E12_ORM_ERROR;
    }
    
    char* err_msg = NULL;
    int rc = sqlite3_exec(trans_impl->db->db, "ROLLBACK", NULL, NULL, &err_msg);
    
    if (rc != SQLITE_OK) {
        set_error(E12_ORM_ERROR_QUERY_FAILED, err_msg ? err_msg : "Failed to rollback transaction");
        if (err_msg) {
            sqlite3_free(err_msg);
        }
        return E12_ORM_ERROR_QUERY_FAILED;
    }
    
    trans_impl->rolled_back = true;
    return E12_ORM_OK;
}

void e12_transaction_free(E12Transaction* transaction) {
    if (!transaction) return;
    
    E12TransactionImpl* trans_impl = (E12TransactionImpl*)transaction;
    
    // Auto-rollback if not committed or rolled back
    if (!trans_impl->committed && !trans_impl->rolled_back) {
        sqlite3_exec(trans_impl->db->db, "ROLLBACK", NULL, NULL, NULL);
    }
    
    free(trans_impl);
}

// ============================================================================
// Connection Pool Operations
// ============================================================================

// Note: Connection pooling is primarily implemented at the Zig level
// These C functions are stubs for future expansion

E12ORMErrorCode e12_pool_create(const char* path, const E12ConnectionPoolConfig* config, E12ConnectionPool** out_pool) {
    clear_error();
    (void)path;
    (void)config;
    (void)out_pool;
    set_error(E12_ORM_ERROR, "Connection pooling not yet implemented in C API");
    return E12_ORM_ERROR;
}

E12ORMErrorCode e12_pool_acquire(E12ConnectionPool* pool, E12Database** out_db) {
    clear_error();
    (void)pool;
    (void)out_db;
    set_error(E12_ORM_ERROR, "Connection pooling not yet implemented in C API");
    return E12_ORM_ERROR;
}

void e12_pool_release(E12ConnectionPool* pool, E12Database* db) {
    (void)pool;
    (void)db;
}

void e12_pool_close(E12ConnectionPool* pool) {
    (void)pool;
}

// ============================================================================
// Error Handling
// ============================================================================

const char* e12_orm_get_last_error(void) {
    if (last_error_code == E12_ORM_OK) {
        return NULL;
    }
    return last_error_msg;
}

E12ORMErrorCode e12_orm_get_last_error_code(void) {
    return last_error_code;
}

