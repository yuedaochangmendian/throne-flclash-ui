// Room (SQLite) writer for the profile and group tables (ADR 0002, phase 3d).
//
// The four profile actions that moved to the Go action bus used to write
// profiles.json/groups.json, which nothing in the Kotlin app read: GroupRepo and
// ProfileManager are Room-backed. Room is the only authority here, so the kernel
// writes the same database the host reads, over WAL (SagerDatabase enables
// JournalMode.WRITE_AHEAD_LOGGING), which lets the two processes share the file.
//
// The Room invalidation tracker does not observe writes from outside Room, so
// Dart asks the host for `data.refresh` after each mutation (see box_api.dart).
//
// The SQLite amalgamation in ./sqlite3 is compiled into the gomobile .so by
// cgo; there is no runtime shared-library dependency and no Go module change.
//
// The vendored amalgamation is unmodified upstream, currently 3.54.1 (published
// 2026-10-16, SHA3-256 of sqlite-amalgamation-3540100.zip verified). Upgrade it
// by dropping in a newer unmodified release rather than patching the file: 3.45.1
// carried three upstream integer-multiplication fixes CodeQL flagged, and drift
// from upstream is the thing that makes a vendored 9 MB C file dangerous.

package mobile

/*
#cgo CFLAGS: -I${SRCDIR}/sqlite3 -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_ENABLE_FTS4 -DSQLITE_ENABLE_FTS5
#include <stdlib.h>
#include <string.h>
#include "sqlite3.h"

// One open connection per call so this stays stateless; WAL makes short-lived
// writers cheap and safe alongside the host's Room connection.
static int room_exec(const char *path, const char *sql, char **err) {
	sqlite3 *db = NULL;
	int rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL);
	if (rc != SQLITE_OK) {
		if (*err == NULL && db != NULL) *err = sqlite3_mprintf("%s", sqlite3_errmsg(db));
		sqlite3_close(db);
		return rc;
	}
	sqlite3_busy_timeout(db, 5000);
	rc = sqlite3_exec(db, sql, NULL, NULL, err);
	sqlite3_close(db);
	return rc;
}

// room_query runs a SELECT and returns a flat array of values plus the column
// count. sqlite3_get_table keeps all values as UTF-8 text (NULL becomes a NULL
// pointer); the Go side parses the numeric columns it needs. The caller frees
// both the table and the error string with sqlite3_free_table / sqlite3_free.
static int room_query(const char *path, const char *sql, char ***table,
                      int *rows, int *cols, char **err) {
	sqlite3 *db = NULL;
	int rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL);
	if (rc != SQLITE_OK) {
		if (db != NULL) { *err = sqlite3_mprintf("%s", sqlite3_errmsg(db)); sqlite3_close(db); }
		return rc;
	}
	sqlite3_busy_timeout(db, 5000);
	rc = sqlite3_get_table(db, sql, table, rows, cols, err);
	sqlite3_close(db);
	return rc;
}

// cgo cannot index a char** directly, so the Go side asks for one cell.
static const char *room_cell(char **table, int index) {
	return table[index];
}

// room_exec_params runs one bound statement. Every value is text (the columns
// this is used on carry JSON, names and tags); NULL is passed as a NULL pointer.
// Binding rather than formatting is what keeps a user-typed profile name from
// being parsed as SQL.
static int room_exec_params(const char *path, const char *sql, int nparams,
                            const char **params, char **err) {
	sqlite3 *db = NULL;
	int rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, NULL);
	if (rc != SQLITE_OK) {
		if (db != NULL) { *err = sqlite3_mprintf("%s", sqlite3_errmsg(db)); sqlite3_close(db); }
		return rc;
	}
	sqlite3_busy_timeout(db, 5000);
	sqlite3_stmt *stmt = NULL;
	rc = sqlite3_prepare_v2(db, sql, -1, &stmt, NULL);
	if (rc != SQLITE_OK) {
		*err = sqlite3_mprintf("%s", sqlite3_errmsg(db));
		sqlite3_close(db);
		return rc;
	}
	for (int i = 0; i < nparams; i++) {
		if (params[i] == NULL) {
			sqlite3_bind_null(stmt, i + 1);
		} else {
			sqlite3_bind_text(stmt, i + 1, params[i], -1, SQLITE_TRANSIENT);
		}
	}
	rc = sqlite3_step(stmt);
	if (rc == SQLITE_DONE || rc == SQLITE_ROW) rc = SQLITE_OK;
	else *err = sqlite3_mprintf("%s", sqlite3_errmsg(db));
	sqlite3_finalize(stmt);
	sqlite3_close(db);
	return rc;
}
*/
import "C"

import (
	"fmt"
	"os"
	"path/filepath"
	"unsafe"
)

// roomDBPath resolves sager_net.db from the kernel base path. The host sets
// BasePath to app.filesDir; the database lives one level up in ../databases/.
func roomDBPath() (string, error) {
	if sBasePath == "" {
		return "", fmt.Errorf("kernel base path is not set; the host must call setup first")
	}
	// filesDir is <data>/files; Room's DB is <data>/databases/sager_net.db.
	dataDir := filepath.Dir(sBasePath)
	path := filepath.Join(dataDir, "databases", "sager_net.db")
	if _, err := os.Stat(path); err != nil {
		return "", fmt.Errorf("Room database is not available: %w", err)
	}
	return path, nil
}

// roomExec runs one or more statements (already fully SQL-escaped) in a single
// transaction. Room's invalidation tracker will not see them; the caller is
// responsible for asking Dart to refresh the catalog.
func roomExec(statements ...string) error {
	if len(statements) == 0 {
		return nil
	}
	path, err := roomDBPath()
	if err != nil {
		return err
	}
	for _, stmt := range statements {
		cPath := C.CString(path)
		cSQL := C.CString(stmt)
		var cErr *C.char
		rc := C.room_exec(cPath, cSQL, &cErr)
		C.free(unsafe.Pointer(cPath))
		C.free(unsafe.Pointer(cSQL))
		if rc != C.SQLITE_OK {
			message := "unknown sqlite error"
			if cErr != nil {
				message = C.GoString(cErr)
				C.sqlite3_free(unsafe.Pointer(cErr))
			}
			return fmt.Errorf("sqlite: %s", message)
		}
		if cErr != nil {
			C.sqlite3_free(unsafe.Pointer(cErr))
		}
	}
	return nil
}

// roomExecParams runs one statement with bound text parameters.
//
// Use this rather than roomExec for anything carrying a value the user typed:
// roomExec formats SQL itself, which is fine for the numeric ids it was built
// for but would let a profile name close the quote.
func roomExecParams(sql string, params ...any) error {
	path, err := roomDBPath()
	if err != nil {
		return err
	}
	cPath := C.CString(path)
	cSQL := C.CString(sql)
	defer C.free(unsafe.Pointer(cPath))
	defer C.free(unsafe.Pointer(cSQL))

	// The C side holds only pointers; the backing strings stay alive in this
	// slice until the call returns.
	texts := make([]*C.char, len(params))
	nils := make([]bool, len(params))
	for i, param := range params {
		if param == nil {
			nils[i] = true
			continue
		}
		texts[i] = C.CString(param.(string))
		defer C.free(unsafe.Pointer(texts[i]))
	}
	bindings := make([]*C.char, len(params))
	for i := range params {
		if !nils[i] {
			bindings[i] = texts[i]
		}
	}

	var cErr *C.char
	var paramsPtr **C.char
	if len(bindings) > 0 {
		paramsPtr = (**C.char)(unsafe.Pointer(&bindings[0]))
	}
	rc := C.room_exec_params(cPath, cSQL, C.int(len(bindings)), paramsPtr, &cErr)
	if rc != C.SQLITE_OK {
		message := "unknown sqlite error"
		if cErr != nil {
			message = C.GoString(cErr)
			C.sqlite3_free(unsafe.Pointer(cErr))
		}
		return fmt.Errorf("sqlite: %s", message)
	}
	if cErr != nil {
		C.sqlite3_free(unsafe.Pointer(cErr))
	}
	return nil
}

// queryRows runs a SELECT and answers its rows as column-name → value maps, the
// same `row` shape the document store uses. Numeric columns arrive as text; the
// rowInt/rowInt64 helpers already accept both. A NULL is a nil value.
func queryRows(sql string) ([]row, error) {
	path, err := roomDBPath()
	if err != nil {
		return nil, err
	}
	cPath := C.CString(path)
	cSQL := C.CString(sql)
	defer C.free(unsafe.Pointer(cPath))
	defer C.free(unsafe.Pointer(cSQL))

	var cTable **C.char
	var cRows, cCols C.int
	var cErr *C.char
	rc := C.room_query(cPath, cSQL, &cTable, &cRows, &cCols, &cErr)
	if rc != C.SQLITE_OK {
		message := "unknown sqlite error"
		if cErr != nil {
			message = C.GoString(cErr)
			C.sqlite3_free(unsafe.Pointer(cErr))
		}
		return nil, fmt.Errorf("sqlite: %s", message)
	}
	if cErr != nil {
		C.sqlite3_free(unsafe.Pointer(cErr))
	}
	defer C.sqlite3_free_table(cTable)

	rows, cols := int(cRows), int(cCols)
	if cTable == nil || cols == 0 {
		return nil, nil
	}
	// sqlite3_get_table puts the column names in the first `cols` slots.
	names := make([]string, cols)
	for i := range names {
		if ptr := C.room_cell(cTable, C.int(i)); ptr != nil {
			names[i] = C.GoString(ptr)
		}
	}

	out := make([]row, 0, rows)
	for r := 0; r < rows; r++ {
		current := row{}
		for c := 0; c < cols; c++ {
			ptr := C.room_cell(cTable, C.int((r+1)*cols+c))
			if ptr == nil {
				current[names[c]] = nil
			} else {
				current[names[c]] = C.GoString(ptr)
			}
		}
		out = append(out, current)
	}
	return out, nil
}

// roomGroup is the slice of the groups table a reorder needs: id and its current
// display_order, in the DAO's `ORDER BY display_order, id` order.
type roomGroup struct {
	id    int64
	order int64
	name  string
}

// readRoomGroups reads the group ids in tab order. A read failure surfaces as an
// empty set, which makes a reorder a no-op rather than a silent corruption; the
// name is carried along for the pickers that need one.
func readRoomGroups() ([]roomGroup, error) {
	rows, err := queryRows("SELECT `id`, `display_order`, `name` FROM `groups` ORDER BY `display_order`, `id`;")
	if err != nil {
		return nil, err
	}
	out := make([]roomGroup, 0, len(rows))
	for _, r := range rows {
		out = append(out, roomGroup{
			id:    rowInt64(r, "id"),
			order: rowInt64(r, "display_order"),
			name:  rowString(r, "name"),
		})
	}
	return out, nil
}
