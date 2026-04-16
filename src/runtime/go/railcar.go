// Package railcar provides an ActiveRecord-like ORM for railcar-generated Go apps.
// Hand-written Go (not transpiled from Crystal).
package railcar

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"nhooyr.io/websocket"
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

// Broadcaster is the optional interface for models with after_save/after_delete hooks.
type Broadcaster interface {
	AfterSave()
	AfterDelete()
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

	var err error
	if m.Persisted() {
		err = doUpdate(m, now)
	} else {
		err = doInsert(m, now)
	}
	if err != nil {
		return err
	}

	// Run after_save callback if model implements Broadcaster
	if b, ok := m.(Broadcaster); ok {
		b.AfterSave()
	}
	return nil
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
	if err != nil {
		return err
	}
	// Run after_delete callback if model implements Broadcaster
	if b, ok := m.(Broadcaster); ok {
		b.AfterDelete()
	}
	return nil
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

// ── Broadcasting ──

// RenderPartialFunc is a function that renders a model to HTML for broadcasting.
type RenderPartialFunc func(m Model) string

// partialRenderers maps model type names to their partial render functions.
var partialRenderers = map[string]RenderPartialFunc{}

// RegisterPartial registers a partial renderer for a model type.
func RegisterPartial(typeName string, fn RenderPartialFunc) {
	partialRenderers[typeName] = fn
}

// TurboStreamHTML generates a turbo-stream HTML fragment.
func TurboStreamHTML(action, target, content string) string {
	if content != "" {
		return fmt.Sprintf(`<turbo-stream action="%s" target="%s"><template>%s</template></turbo-stream>`, action, target, content)
	}
	return fmt.Sprintf(`<turbo-stream action="%s" target="%s"></turbo-stream>`, action, target)
}

// DomIDFor returns the dom_id for a model instance.
func DomIDFor(m Model) string {
	name := strings.TrimSuffix(m.TableName(), "s") // simple singularize
	return fmt.Sprintf("%s_%d", name, m.ID())
}

// RenderPartial renders a model using its registered partial renderer.
func RenderPartial(m Model) string {
	typeName := fmt.Sprintf("%T", m)
	if i := strings.LastIndex(typeName, "."); i >= 0 {
		typeName = typeName[i+1:]
	}
	typeName = strings.TrimPrefix(typeName, "*")
	if fn, ok := partialRenderers[typeName]; ok {
		return fn(m)
	}
	return fmt.Sprintf("<div>%v</div>", m)
}

// BroadcastReplaceTo broadcasts a replace turbo-stream to the given channel.
func BroadcastReplaceTo(m Model, channel string, target string) {
	if target == "" {
		target = DomIDFor(m)
	}
	html := RenderPartial(m)
	stream := TurboStreamHTML("replace", target, html)
	Cable.Broadcast(channel, stream)
}

// BroadcastAppendTo broadcasts an append turbo-stream to the given channel.
func BroadcastAppendTo(m Model, channel string, target string) {
	if target == "" {
		target = m.TableName()
	}
	html := RenderPartial(m)
	stream := TurboStreamHTML("append", target, html)
	Cable.Broadcast(channel, stream)
}

// BroadcastPrependTo broadcasts a prepend turbo-stream to the given channel.
func BroadcastPrependTo(m Model, channel string, target string) {
	if target == "" {
		target = m.TableName()
	}
	html := RenderPartial(m)
	stream := TurboStreamHTML("prepend", target, html)
	Cable.Broadcast(channel, stream)
}

// BroadcastRemoveTo broadcasts a remove turbo-stream to the given channel.
func BroadcastRemoveTo(m Model, channel string, target string) {
	if target == "" {
		target = DomIDFor(m)
	}
	stream := TurboStreamHTML("remove", target, "")
	Cable.Broadcast(channel, stream)
}

// ── CableServer (Action Cable WebSocket pub/sub) ──

type subscriber struct {
	conn       *websocket.Conn
	ctx        context.Context
	identifier string
}

// CableServer manages WebSocket subscriptions and broadcasts.
type CableServer struct {
	mu       sync.RWMutex
	channels map[string][]subscriber
}

// Cable is the global CableServer instance.
var Cable = &CableServer{channels: make(map[string][]subscriber)}

// Subscribe adds a WebSocket connection to a channel.
func (cs *CableServer) Subscribe(channel string, conn *websocket.Conn, ctx context.Context, identifier string) {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	cs.channels[channel] = append(cs.channels[channel], subscriber{conn, ctx, identifier})
}

// Unsubscribe removes a WebSocket connection from all channels.
func (cs *CableServer) Unsubscribe(conn *websocket.Conn) {
	cs.mu.Lock()
	defer cs.mu.Unlock()
	for ch, subs := range cs.channels {
		var kept []subscriber
		for _, s := range subs {
			if s.conn != conn {
				kept = append(kept, s)
			}
		}
		if len(kept) > 0 {
			cs.channels[ch] = kept
		} else {
			delete(cs.channels, ch)
		}
	}
}

// Broadcast sends a message to all subscribers of a channel.
func (cs *CableServer) Broadcast(channel string, html string) {
	cs.mu.RLock()
	subs := cs.channels[channel]
	cs.mu.RUnlock()

	for _, s := range subs {
		msg, _ := json.Marshal(map[string]string{
			"type":       "message",
			"identifier": s.identifier,
			"message":    html,
		})
		s.conn.Write(s.ctx, websocket.MessageText, msg)
	}
}

// CableHandler handles Action Cable WebSocket connections at /cable.
func CableHandler(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		Subprotocols: []string{"actioncable-v1-json"},
	})
	if err != nil {
		log.Println("WebSocket accept error:", err)
		return
	}
	defer func() {
		Cable.Unsubscribe(conn)
		conn.Close(websocket.StatusNormalClosure, "")
	}()

	ctx := r.Context()

	// Send welcome
	welcome, _ := json.Marshal(map[string]string{"type": "welcome"})
	conn.Write(ctx, websocket.MessageText, welcome)

	// Start ping loop
	go func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case t := <-ticker.C:
				ping, _ := json.Marshal(map[string]any{"type": "ping", "message": t.Unix()})
				if err := conn.Write(ctx, websocket.MessageText, ping); err != nil {
					return
				}
			}
		}
	}()

	// Read messages
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}

		var msg map[string]string
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}

		if msg["command"] == "subscribe" {
			identifier := msg["identifier"]
			// Decode channel from identifier: {"channel":"...","signed_stream_name":"base64--sig"}
			var idData map[string]string
			json.Unmarshal([]byte(identifier), &idData)
			signed := idData["signed_stream_name"]
			// Extract base64 portion before "--"
			parts := strings.SplitN(signed, "--", 2)
			if len(parts) == 0 {
				continue
			}
			decoded, err := base64.StdEncoding.DecodeString(parts[0])
			if err != nil {
				continue
			}
			// Decoded is a JSON string, e.g., "\"articles\"" or "\"article_1_comments\""
			var channel string
			json.Unmarshal(decoded, &channel)

			Cable.Subscribe(channel, conn, ctx, identifier)

			confirm, _ := json.Marshal(map[string]string{
				"type":       "confirm_subscription",
				"identifier": identifier,
			})
			conn.Write(ctx, websocket.MessageText, confirm)
		}
	}
}
