package main

import (
	"fmt"
	"time"
)

type Post struct {
	Title   string    `yaml:"title"`
	Date    time.Time `yaml:"date"`
	Tags    []string  `yaml:"tags"`
	Slug    string    `yaml:"slug"`
	Content string    // rendered HTML
}

// ParsePost reads a markdown file and returns a Post.
func ParsePost(path string) (Post, error) {
	return Post{}, fmt.Errorf("not implemented")
}

// LoadPosts reads all .md files from a directory, sorted by date descending.
func LoadPosts(dir string) ([]Post, error) {
	return nil, fmt.Errorf("not implemented")
}
