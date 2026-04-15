package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/yuin/goldmark"
	"gopkg.in/yaml.v3"
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
	data, err := os.ReadFile(path)
	if err != nil {
		return Post{}, err
	}

	// Split frontmatter from content.
	// Frontmatter is between the first two "---" lines.
	content := string(data)
	if !strings.HasPrefix(content, "---\n") {
		return Post{}, fmt.Errorf("missing frontmatter in %s", path)
	}
	parts := strings.SplitN(content[4:], "\n---\n", 2)
	if len(parts) != 2 {
		return Post{}, fmt.Errorf("malformed frontmatter in %s", path)
	}

	var post Post
	if err := yaml.Unmarshal([]byte(parts[0]), &post); err != nil {
		return Post{}, fmt.Errorf("parsing frontmatter in %s: %w", path, err)
	}

	// Render markdown to HTML.
	var buf bytes.Buffer
	if err := goldmark.Convert([]byte(parts[1]), &buf); err != nil {
		return Post{}, fmt.Errorf("rendering markdown in %s: %w", path, err)
	}
	post.Content = buf.String()

	return post, nil
}

// LoadPosts reads all .md files from a directory, sorted by date descending.
func LoadPosts(dir string) ([]Post, error) {
	entries, err := filepath.Glob(filepath.Join(dir, "*.md"))
	if err != nil {
		return nil, err
	}

	var posts []Post
	for _, path := range entries {
		post, err := ParsePost(path)
		if err != nil {
			return nil, err
		}
		posts = append(posts, post)
	}

	sort.Slice(posts, func(i, j int) bool {
		return posts[i].Date.After(posts[j].Date)
	})

	return posts, nil
}
