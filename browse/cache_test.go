package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func testCache(t *testing.T, render func(context.Context, string) ([]byte, error)) *pageCache {
	t.Helper()
	c, err := newPageCache(t.TempDir(), cacheTTL, cacheMaxBytes, render)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func getPage(t *testing.T, c *pageCache, id string) cachedPage {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	page, err := c.get(ctx, id)
	if err != nil {
		t.Fatal(err)
	}
	return page
}

func TestCacheConcurrentMissesAndDiskHits(t *testing.T) {
	var calls atomic.Int32
	started, release := make(chan struct{}), make(chan struct{})
	c := testCache(t, func(context.Context, string) ([]byte, error) {
		calls.Add(1)
		close(started)
		<-release
		return []byte("complete page"), nil
	})
	var wg sync.WaitGroup
	for range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if page := getPage(t, c, "42"); string(page.html) != "complete page" {
				t.Errorf("unexpected page: %s", page.html)
			}
		}()
	}
	<-started
	close(release)
	wg.Wait()
	if calls.Load() != 1 {
		t.Fatalf("render count = %d", calls.Load())
	}
	// A disk read, rather than an in-memory body cache, must see the changed file.
	if err := os.WriteFile(c.path("42"), []byte("disk"), 0600); err != nil {
		t.Fatal(err)
	}
	if string(getPage(t, c, "42").html) != "disk" || calls.Load() != 1 {
		t.Fatal("cache hit did not read disk without rendering")
	}
}

func TestInvalidationDuringRender(t *testing.T) {
	var calls atomic.Int32
	started, release := make(chan struct{}), make(chan struct{})
	c := testCache(t, func(context.Context, string) ([]byte, error) {
		if calls.Add(1) == 1 {
			close(started)
			<-release
			return []byte("old"), nil
		}
		return []byte("new"), nil
	})
	result := make(chan cachedPage, 1)
	go func() { result <- getPage(t, c, "42") }()
	<-started
	if err := c.invalidate("42"); err != nil {
		t.Fatal(err)
	}
	close(release)
	if page := <-result; string(page.html) != "new" {
		t.Fatalf("served invalidated render: %s", page.html)
	}
	if page := getPage(t, c, "42"); string(page.html) != "new" || calls.Load() != 2 {
		t.Fatal("invalidated render repopulated cache")
	}
}

func TestTTLDoesNotExtendOnHitsAndNeverFallsBack(t *testing.T) {
	var clock atomic.Int64
	var calls atomic.Int32
	fail := atomic.Bool{}
	c := testCache(t, func(context.Context, string) ([]byte, error) {
		calls.Add(1)
		if fail.Load() {
			return []byte("incomplete"), errors.New("source unavailable")
		}
		return []byte("complete"), nil
	})
	c.now = func() time.Time { return time.Unix(clock.Load(), 0) }
	getPage(t, c, "42")
	clock.Store(59)
	getPage(t, c, "42")
	clock.Store(60)
	fail.Store(true)
	if _, err := c.get(context.Background(), "42"); err == nil {
		t.Fatal("expired entry fell back to stale or partial HTML")
	}
	fail.Store(false)
	getPage(t, c, "42")
	if calls.Load() != 3 {
		t.Fatalf("render calls = %d", calls.Load())
	}
}

func TestRestartClearsOnlyCacheDirectory(t *testing.T) {
	parent := t.TempDir()
	dir := filepath.Join(parent, "recipe-html")
	render := func(context.Context, string) ([]byte, error) { return []byte("page"), nil }
	c, err := newPageCache(dir, cacheTTL, cacheMaxBytes, render)
	if err != nil {
		t.Fatal(err)
	}
	getPage(t, c, "42")
	neighbor := filepath.Join(parent, "keep")
	if err := os.WriteFile(neighbor, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	c, err = newPageCache(dir, cacheTTL, cacheMaxBytes, render)
	if err != nil {
		t.Fatal(err)
	}
	files, err := os.ReadDir(dir)
	if err != nil || len(files) != 0 || len(c.entries) != 0 {
		t.Fatalf("cache not cleared: %v %v", files, err)
	}
	if _, err := os.Stat(neighbor); err != nil {
		t.Fatal("startup touched neighboring storage")
	}
}

func TestStorageLimitAndFailures(t *testing.T) {
	c := testCache(t, func(_ context.Context, id string) ([]byte, error) { return []byte(id), nil })
	c.limit = 5
	getPage(t, c, "aaa")
	getPage(t, c, "bbb")
	if _, err := os.Stat(c.path("aaa")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("oldest entry was not evicted")
	}
	if c.used != 3 {
		t.Fatalf("stored bytes = %d", c.used)
	}
	if _, err := c.get(context.Background(), "too large"); err == nil {
		t.Fatal("oversized page accepted")
	}
	// A nonempty directory at the entry path simulates a deletion failure even as root.
	if err := os.Remove(c.path("bbb")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(c.path("bbb"), 0700); err != nil {
		t.Fatal(err)
	}
	blocker := filepath.Join(c.path("bbb"), "block")
	if err := os.WriteFile(blocker, nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := c.invalidate("bbb"); err == nil {
		t.Fatal("invalidation failure hidden")
	}
	if _, err := c.get(context.Background(), "bbb"); err == nil {
		t.Fatal("failed invalidation left an accessible entry")
	}
	if err := os.Remove(blocker); err != nil {
		t.Fatal(err)
	}
	if err := c.invalidate("bbb"); err != nil {
		t.Fatal(err)
	}
	if err := c.invalidate("bbb"); err != nil {
		t.Fatal("duplicate invalidation failed")
	}
	getPage(t, c, "bbb")
}

func TestFailedRenderAndAtomicWriteNeverCached(t *testing.T) {
	fail := true
	c := testCache(t, func(context.Context, string) ([]byte, error) {
		if fail {
			return []byte("partial"), errors.New("render failed")
		}
		return []byte("complete"), nil
	})
	if _, err := c.get(context.Background(), "42"); err == nil {
		t.Fatal("partial render accepted")
	}
	files, err := os.ReadDir(c.dir)
	if err != nil || len(files) != 0 {
		t.Fatal("failed render persisted")
	}
	fail = false
	// Force atomic rename to fail after a successful render.
	if err := os.Mkdir(c.path("42"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(c.path("42"), "block"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := c.get(context.Background(), "42"); err == nil {
		t.Fatal("failed atomic publication accepted")
	}
	files, err = os.ReadDir(c.dir)
	if err != nil || len(files) != 1 || c.used != 0 {
		t.Fatal("failed publication leaked temporary HTML or metadata")
	}
}
