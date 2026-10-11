package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

func eventData(t *testing.T, kind string, id *string) []byte {
	t.Helper()
	data, err := json.Marshal(recipeEvent{
		Version: 1, EventID: uuid.NewString(), OccurredAt: time.Now().UTC().Format(time.RFC3339Nano),
		Kind: kind, RecipeID: id,
	})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestEventContract(t *testing.T) {
	id := "42"
	var events [][]byte
	for _, kind := range []string{"recipe.changed", "recipe.deleted", "rating.changed", "image.changed", "inspirations.changed"} {
		events = append(events, eventData(t, kind, &id))
	}
	for _, kind := range []string{"recipes.reset", "ratings.reset", "images.reset", "inspirations.reset"} {
		events = append(events, eventData(t, kind, nil))
	}
	c := testCache(t, func(context.Context, string) ([]byte, error) { return []byte("page"), nil })
	for _, event := range events {
		getPage(t, c, "42")
		getPage(t, c, "other")
		var envelope recipeEvent
		if err := json.Unmarshal(event, &envelope); err != nil {
			t.Fatal(err)
		}
		if envelope.RecipeID != nil {
			getPage(t, c, *envelope.RecipeID)
		}
		for range 2 {
			if err := c.applyEvent(event); err != nil {
				t.Fatal(err)
			}
		}
		if envelope.RecipeID == nil && len(c.entries) != 0 {
			t.Fatal("reset did not invalidate every page")
		}
		if envelope.RecipeID != nil {
			if _, ok := c.entries[*envelope.RecipeID]; ok {
				t.Fatal("recipe event did not invalidate its page")
			}
			if _, ok := c.entries["other"]; !ok {
				t.Fatal("recipe event invalidated unrelated page")
			}
		}
	}
	for _, malformed := range []string{
		`{`, `{}`, `{"version":2}`, `{"version":1,"eventId":"bad"}`,
	} {
		if err := c.applyEvent([]byte(malformed)); err == nil {
			t.Fatalf("accepted malformed event: %s", malformed)
		}
	}
	for _, invalid := range [][]byte{
		eventData(t, "unknown", &id),
		eventData(t, "recipe.changed", nil),
		eventData(t, "recipes.reset", &id),
	} {
		if err := c.applyEvent(invalid); err == nil {
			t.Fatalf("accepted invalid event: %s", invalid)
		}
	}
}

func eventually(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("condition not met within healthy-path five-second target")
}

func startBroker(t *testing.T, opts *server.Options) *server.Server {
	t.Helper()
	s, err := server.NewServer(opts)
	if err != nil {
		t.Fatal(err)
	}
	s.Start()
	if !s.ReadyForConnections(5 * time.Second) {
		t.Fatal("test broker not ready")
	}
	t.Cleanup(func() { s.Shutdown(); s.WaitForShutdown() })
	return s
}

func TestJetStreamInvalidationRetriesAndOutageRecovery(t *testing.T) {
	opts := &server.Options{Host: "127.0.0.1", Port: -1, JetStream: true, StoreDir: t.TempDir(), NoLog: true, NoSigs: true}
	s := startBroker(t, opts)
	nc, err := nats.Connect(s.ClientURL(), nats.MaxReconnects(-1), nats.ReconnectWait(50*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	defer nc.Close()
	js, err := jetstream.New(nc)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stream, err := js.CreateStream(ctx, jetstream.StreamConfig{
		Name: eventStream, Subjects: []string{eventSubject}, Storage: jetstream.FileStorage,
		Retention: jetstream.LimitsPolicy,
	})
	if err != nil {
		t.Fatal(err)
	}
	consumer, err := stream.CreateConsumer(ctx, jetstream.ConsumerConfig{
		Durable: cacheConsumer, FilterSubject: eventSubject, AckPolicy: jetstream.AckExplicitPolicy,
		AckWait: 30 * time.Second, MaxAckPending: 16,
	})
	if err != nil {
		t.Fatal(err)
	}
	search, err := stream.CreateConsumer(ctx, jetstream.ConsumerConfig{
		Durable: "search-index-v1", FilterSubject: eventSubject, AckPolicy: jetstream.AckExplicitPolicy,
	})
	if err != nil {
		t.Fatal(err)
	}
	var clock atomic.Int64
	var offline atomic.Bool
	var calls atomic.Int32
	c := testCache(t, func(context.Context, string) ([]byte, error) {
		calls.Add(1)
		if offline.Load() {
			return nil, errors.New("GraphQL unavailable")
		}
		return []byte("page"), nil
	})
	c.now = func() time.Time { return time.Unix(clock.Load(), 0) }
	done := make(chan struct{})
	brokerURL := s.ClientURL()
	go func() {
		defer close(done)
		c.watchEvents(ctx, brokerURL)
	}()
	defer func() {
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("consumer did not stop")
		}
	}()
	eventually(t, func() bool {
		info, err := consumer.Info(ctx)
		return err == nil && info.NumWaiting > 0
	})
	id := "42"
	publish := func(data []byte) {
		t.Helper()
		if _, err := js.Publish(ctx, eventSubject, data); err != nil {
			t.Fatal(err)
		}
	}
	waitAck := func(sequence uint64) {
		t.Helper()
		eventually(t, func() bool {
			info, err := consumer.Info(ctx)
			return err == nil && info.AckFloor.Stream >= sequence && info.NumAckPending == 0
		})
	}
	getPage(t, c, id)
	data := eventData(t, "image.changed", &id)
	publish(data)
	publish(data) // Duplicate delivery remains safe without an application deduplication set.
	waitAck(2)
	c.mu.Lock()
	_, cached := c.entries[id]
	c.mu.Unlock()
	if cached {
		t.Fatal("bus delivery did not invalidate page")
	}
	searchInfo, err := search.Info(ctx)
	if err != nil || searchInfo.NumPending != 2 {
		t.Fatal("browse acknowledgement consumed search's events")
	}
	getPage(t, c, id)
	if err := os.Remove(c.path(id)); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(c.path(id), 0700); err != nil {
		t.Fatal(err)
	}
	blocker := filepath.Join(c.path(id), "block")
	if err := os.WriteFile(blocker, nil, 0600); err != nil {
		t.Fatal(err)
	}
	publish(eventData(t, "recipe.changed", &id))
	eventually(t, func() bool {
		c.mu.Lock()
		defer c.mu.Unlock()
		return !c.entries[id].valid
	})
	info, err := consumer.Info(ctx)
	if err != nil || info.AckFloor.Stream >= 3 {
		t.Fatal("failed invalidation was acknowledged")
	}
	if err := os.Remove(blocker); err != nil {
		t.Fatal(err)
	}
	waitAck(3)
	getPage(t, c, id)
	// Stop and restart the actual broker with the same disk store and port.
	url := s.ClientURL()
	port := s.Addr().(*net.TCPAddr).Port
	s.Shutdown()
	s.WaitForShutdown()
	offline.Store(true)
	clock.Store(59)
	getPage(t, c, id)
	clock.Store(60)
	if _, err := c.get(ctx, id); err == nil {
		t.Fatal("bus outage allowed stale fallback past TTL")
	}
	offline.Store(false)
	getPage(t, c, id)
	opts.Port = port
	s = startBroker(t, opts)
	if s.ClientURL() != url {
		t.Fatal("broker restart changed address")
	}
	eventually(t, func() bool { return nc.IsConnected() })
	publish(eventData(t, "recipe.deleted", &id))
	waitAck(4)
	c.mu.Lock()
	_, cached = c.entries[id]
	c.mu.Unlock()
	if cached {
		t.Fatal("consumer failed to resume invalidation after broker outage")
	}
}
