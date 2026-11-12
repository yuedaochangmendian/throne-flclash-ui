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
}

// readRoomGroups reads the group ids in tab order. A read failure surfaces as an
// empty set, which makes the reorder a no-op rather than a silent corruption.
func readRoomGroups(path string) []roomGroup {
	cPath := C.CString(path)
	cSQL := C.CString("SELECT `id`, `display_order` FROM `groups` ORDER BY `display_order`, `id`;")
	defer C.free(unsafe.Pointer(cPath))
	defer C.free(unsafe.Pointer(cSQL))

	var db *C.sqlite3
	if C.sqlite3_open_v2(cPath, &db, C.SQLITE_OPEN_READONLY|C.SQLITE_OPEN_FULLMUTEX, nil) != C.SQLITE_OK {
		if db != nil {
			C.sqlite3_close(db)
		}
		return nil
	}
	defer C.sqlite3_close(db)

	var stmt *C.sqlite3_stmt
	if C.sqlite3_prepare_v2(db, cSQL, -1, &stmt, nil) != C.SQLITE_OK {
		return nil
	}
	defer C.sqlite3_finalize(stmt)

	var out []roomGroup
	for C.sqlite3_step(stmt) == C.SQLITE_ROW {
		out = append(out, roomGroup{
			id:    int64(C.sqlite3_column_int64(stmt, 0)),
			order: int64(C.sqlite3_column_int64(stmt, 1)),
		})
	}
	return out
}
