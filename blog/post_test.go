package main

import (
	"strings"
	"testing"
	"time"
)

func TestParsePost(t *testing.T) {
	post, err := ParsePost("testdata/valid-post.md")
	if err != nil {
		t.Fatalf("ParsePost returned error: %v", err)
	}

	if post.Title != "Test Post" {
		t.Errorf("Title = %q, want %q", post.Title, "Test Post")
	}
	if post.Slug != "test-post" {
		t.Errorf("Slug = %q, want %q", post.Slug, "test-post")
	}
	expectedDate := time.Date(2026, 1, 15, 0, 0, 0, 0, time.UTC)
	if !post.Date.Equal(expectedDate) {
		t.Errorf("Date = %v, want %v", post.Date, expectedDate)
	}
	if len(post.Tags) != 2 || post.Tags[0] != "go" || post.Tags[1] != "test" {
		t.Errorf("Tags = %v, want [go test]", post.Tags)
	}
	if !strings.Contains(post.Content, "<strong>test</strong>") {
		t.Errorf("Content missing rendered markdown, got: %s", post.Content)
	}
	if !strings.Contains(post.Content, "<li>Item one</li>") {
		t.Errorf("Content missing list items, got: %s", post.Content)
	}
}

func TestParsePostMissingFile(t *testing.T) {
	_, err := ParsePost("testdata/nonexistent.md")
	if err == nil {
		t.Fatal("expected error for missing file, got nil")
	}
}

func TestParsePostNoFrontmatter(t *testing.T) {
	// Will be tested after we create the fixture in the implementation step
}
