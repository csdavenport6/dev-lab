package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func testServer(t *testing.T) *Server {
	t.Helper()
	srv, err := NewServer("testdata", "testdata/templates")
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	return srv
}

func TestHandleIndex(t *testing.T) {
	srv := testServer(t)
	req := httptest.NewRequest("GET", "/", nil)
	w := httptest.NewRecorder()

	srv.HandleIndex(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", w.Code, http.StatusOK)
	}
	body := w.Body.String()
	if !strings.Contains(body, "Second Post") {
		t.Errorf("index page missing 'Second Post', got: %s", body)
	}
	if !strings.Contains(body, "Test Post") {
		t.Errorf("index page missing 'Test Post', got: %s", body)
	}
}

func TestHandlePost(t *testing.T) {
	srv := testServer(t)
	req := httptest.NewRequest("GET", "/posts/test-post", nil)
	w := httptest.NewRecorder()

	srv.HandlePost(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("status = %d, want %d", w.Code, http.StatusOK)
	}
	body := w.Body.String()
	if !strings.Contains(body, "Test Post") {
		t.Errorf("post page missing 'Test Post', got: %s", body)
	}
	if !strings.Contains(body, "<strong>test</strong>") {
		t.Errorf("post page missing rendered markdown, got: %s", body)
	}
}

func TestHandlePostNotFound(t *testing.T) {
	srv := testServer(t)
	req := httptest.NewRequest("GET", "/posts/nonexistent", nil)
	w := httptest.NewRecorder()

	srv.HandlePost(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("status = %d, want %d", w.Code, http.StatusNotFound)
	}
}

func TestHandleHealth(t *testing.T) {
	srv := testServer(t)
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()

	srv.HandleHealth(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusOK)
	}
	if body := strings.TrimSpace(w.Body.String()); body != "ok" {
		t.Fatalf("body = %q, want %q", body, "ok")
	}
}

func TestHandleHealthMethodNotAllowed(t *testing.T) {
	srv := testServer(t)
	req := httptest.NewRequest(http.MethodPost, "/healthz", nil)
	w := httptest.NewRecorder()

	srv.HandleHealth(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusMethodNotAllowed)
	}
	if allow := w.Header().Get("Allow"); allow != http.MethodGet {
		t.Fatalf("allow header = %q, want %q", allow, http.MethodGet)
	}
}
