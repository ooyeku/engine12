#ifndef E12_ORM_H
#define E12_ORM_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handles - these are pointer types, never dereference them
typedef void E12Database;
typedef void E12Result;
typedef void E12Row;

// Error codes
typedef enum {
    E12_ORM_OK = 0,
    E12_ORM_ERROR = 1,
    E12_ORM_ERROR_OPEN_FAILED = 2,
    E12_ORM_ERROR_QUERY_FAILED = 3,
    E12_ORM_ERROR_INVALID_ARGUMENT = 4,
    E12_ORM_ERROR_NO_RESULTS = 5,
} E12ORMErrorCode;

// ============================================================================
// Database Operations
// ============================================================================

/// Open a SQLite database
/// @param path Database file path (will be created if doesn't exist)
/// @param out_db Output parameter for the database handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_db_open(const char* path, E12Database** out_db);

/// Close a database connection
/// @param db Database handle (must not be NULL)
void e12_db_close(E12Database* db);

/// Execute a SQL statement (INSERT, UPDATE, DELETE, CREATE TABLE, etc.)
/// @param db Database handle
/// @param sql SQL statement string
/// @param rows_affected Output parameter for number of rows affected (can be NULL)
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_db_execute(E12Database* db, const char* sql, int64_t* rows_affected);

// ============================================================================
// Query Operations
// ============================================================================

/// Execute a SELECT query and return a result set
/// @param db Database handle
/// @param sql SQL SELECT statement
/// @param out_result Output parameter for the result handle
/// @return E12_ORM_OK on success, error code on failure
E12ORMErrorCode e12_db_query(E12Database* db, const char* sql, E12Result** out_result);

/// Get the number of columns in a result set
/// @param result Result handle
/// @return Number of columns, or 0 if invalid
int e12_result_column_count(E12Result* result);

/// Get the name of a column by index
/// @param result Result handle
/// @param col_index Column index (0-based)
/// @return Column name (owned by result, do not free), NULL if invalid
const char* e12_result_column_name(E12Result* result, int col_index);

/// Get the next row from the result set
/// @param result Result handle
/// @param out_row Output parameter for the row handle (NULL if no more rows)
/// @return true if a row was returned, false if no more rows
bool e12_result_next_row(E12Result* result, E12Row** out_row);

/// Free a result set
/// @param result Result handle to free
void e12_result_free(E12Result* result);

// ============================================================================
// Row Operations
// ============================================================================

/// Get a text value from a row by column index
/// @param row Row handle
/// @param col_index Column index (0-based)
/// @return Text value (owned by result, do not free), NULL if invalid or NULL in database
const char* e12_row_get_text(E12Row* row, int col_index);

/// Get an integer value from a row by column index
/// @param row Row handle
/// @param col_index Column index (0-based)
/// @return Integer value, or 0 if invalid or NULL in database
int64_t e12_row_get_int64(E12Row* row, int col_index);

/// Get a double value from a row by column index
/// @param row Row handle
/// @param col_index Column index (0-based)
/// @return Double value, or 0.0 if invalid or NULL in database
double e12_row_get_double(E12Row* row, int col_index);

/// Check if a column value is NULL
/// @param row Row handle
/// @param col_index Column index (0-based)
/// @return true if NULL, false otherwise
bool e12_row_is_null(E12Row* row, int col_index);

/// Free a row handle
/// @param row Row handle to free
void e12_row_free(E12Row* row);

// ============================================================================
// Error Handling
// ============================================================================

/// Get the last error message
/// @return Error message string (owned by ORM, do not free), NULL if no error
const char* e12_orm_get_last_error(void);

/// Get the last error code
/// @return Error code
E12ORMErrorCode e12_orm_get_last_error_code(void);

#ifdef __cplusplus
}
#endif

#endif // E12_ORM_H

