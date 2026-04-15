// Package railcar provides an ActiveRecord-like ORM for railcar-generated Go apps.
// Hand-written Go (not transpiled from Crystal).
package railcar

import (
	"database/sql"
	"fmt"
	"strings"
	"time"
)

// DB is the shared database connection.
var DB *sql.DB

// ValidationError represents a single field validation error.
type ValidationError struct {
	Field   string
	Message string
}

func (e ValidationError) FullMessage() string {
	field := strings.ReplaceAll(e.Field, "_", " ")
	if len(field) > 0 {
		field = strings.ToUpper(field[:1]) + field[1:]
	}
	return field + " " + e.Message
}

// Model is the interface that all railcar models implement.
type Model interface {
	TableName() string
	Columns() []string
	ID() int64
	SetID(int64)
	Persisted() bool
	SetPersisted(bool)
	Errors() []ValidationError
	SetErrors([]ValidationError)
	RunValidations() []ValidationError
	ScanRow(*sql.Rows) error
	ColumnValues() []any
	ColumnValuesForUpdate() []any
}

// Find loads a model by ID.
func Find(m Model, id int64) error {
	rows, err := DB.Query("SELECT * FROM "+m.TableName()+" WHERE id = ?", id)
	if err != nil {
		return fmt.Errorf("%s not found: %d", m.TableName(), id)
	}
	defer rows.Close()
	if !rows.Next() {
		return fmt.Errorf("%s not found: %d", m.TableName(), id)
	}
	if err := m.ScanRow(rows); err != nil {
		return err
	}
	m.SetPersisted(true)
	return nil
}

// All returns all records ordered by the given column.
func All[T Model](factory func() T, tableName string, orderBy string) ([]T, error) {
	rows, err := DB.Query("SELECT * FROM " + tableName + " ORDER BY " + orderBy)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []T
	for rows.Next() {
		record := factory()
		if err := record.ScanRow(rows); err != nil {
			return nil, err
		}
		record.SetPersisted(true)
		results = append(results, record)
	}
	return results, nil
}

// Where returns records matching conditions.
func Where[T Model](factory func() T, tableName string, conditions map[string]any) ([]T, error) {
	var clauses []string
	var values []any
	for k, v := range conditions {
		clauses = append(clauses, k+" = ?")
		values = append(values, v)
	}
	query := "SELECT * FROM " + tableName + " WHERE " + strings.Join(clauses, " AND ")
	rows, err := DB.Query(query, values...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var results []T
	for rows.Next() {
		record := factory()
		if err := record.ScanRow(rows); err != nil {
			return nil, err
		}
		record.SetPersisted(true)
		results = append(results, record)
	}
	return results, nil
}

// Count returns the number of records in a table.
func Count(tableName string) (int, error) {
	var count int
	err := DB.QueryRow("SELECT COUNT(*) FROM " + tableName).Scan(&count)
	return count, err
}

// Save inserts or updates a record.
func Save(m Model) error {
	errors := m.RunValidations()
	if len(errors) > 0 {
		m.SetErrors(errors)
		return fmt.Errorf("validation failed")
	}
	m.SetErrors(nil)

	now := time.Now().UTC().Format("2006-01-02 15:04:05.000000")

	if m.Persisted() {
		return doUpdate(m, now)
	}
	return doInsert(m, now)
}

func doInsert(m Model, now string) error {
	// Use ColumnValues (excludes id and timestamps)
	values := m.ColumnValues()

	// Build column list matching ColumnValues (no id, no timestamps)
	var cols []string
	for _, c := range m.Columns() {
		if c != "created_at" && c != "updated_at" {
			cols = append(cols, c)
		}
	}

	// Add timestamps
	hasTimes := false
	for _, c := range m.Columns() {
		if c == "created_at" {
			hasTimes = true
			break
		}
	}
	if hasTimes {
		cols = append(cols, "created_at", "updated_at")
		values = append(values, now, now)
	}

	placeholders := make([]string, len(cols))
	for i := range cols {
		placeholders[i] = "?"
	}

	query := fmt.Sprintf("INSERT INTO %s (%s) VALUES (%s)",
		m.TableName(), strings.Join(cols, ", "), strings.Join(placeholders, ", "))

	result, err := DB.Exec(query, values...)
	if err != nil {
		return err
	}

	id, err := result.LastInsertId()
	if err != nil {
		return err
	}
	m.SetID(id)
	m.SetPersisted(true)
	return nil
}

func doUpdate(m Model, now string) error {
	cols := m.ColumnValuesForUpdate()
	updateCols := m.Columns()

	// Filter out created_at, add updated_at
	var setClauses []string
	var values []any
	for i, c := range updateCols {
		if c == "created_at" {
			continue
		}
		if c == "updated_at" {
			setClauses = append(setClauses, c+" = ?")
			values = append(values, now)
		} else {
			setClauses = append(setClauses, c+" = ?")
			values = append(values, cols[i])
		}
	}
	values = append(values, m.ID())

	query := fmt.Sprintf("UPDATE %s SET %s WHERE id = ?",
		m.TableName(), strings.Join(setClauses, ", "))

	_, err := DB.Exec(query, values...)
	return err
}

// Delete removes a record from the database.
func Delete(m Model) error {
	_, err := DB.Exec("DELETE FROM "+m.TableName()+" WHERE id = ?", m.ID())
	return err
}

// Pluralize returns a simple English pluralization.
func Pluralize(count int, singular string) string {
	if count == 1 {
		return fmt.Sprintf("%d %s", count, singular)
	}
	return fmt.Sprintf("%d %ss", count, singular)
}

// Truncate truncates a string to the given length.
func Truncate(text string, length int) string {
	if len(text) <= length {
		return text
	}
	if length <= 3 {
		return text[:length]
	}
	return text[:length-3] + "..."
}
