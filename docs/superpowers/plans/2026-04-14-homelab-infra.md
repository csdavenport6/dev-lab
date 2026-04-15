# Homelab Infrastructure & Blog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A fully reproducible DigitalOcean droplet serving a Go blog at `https://cdavenport.io`, provisioned entirely via Terraform + cloud-init.

**Architecture:** Terraform provisions the DO droplet, DNS, and cloud firewall. A cloud-init template hardens the server and starts a Docker Compose stack (Caddy reverse proxy + Go blog). Blog posts are markdown files rendered server-side.

**Tech Stack:** Go 1.24, goldmark, gopkg.in/yaml.v3, Docker, Docker Compose, Caddy 2, Terraform (digitalocean/digitalocean provider), cloud-init, UFW, fail2ban

**Prerequisites:**
- DigitalOcean account with API token
- SSH key added to DigitalOcean (note the key name)
- GitHub repo created (public, or with deploy key) — needed for cloud-init to clone on the server
- Terraform installed locally
- Go 1.24+ installed locally
- Docker installed locally (for local testing)

---

### Task 1: Project Scaffolding

**Files:**
- Create: `.gitignore`

- [ ] **Step 1: Create .gitignore**

```gitignore
# Terraform
terraform/.terraform/
terraform/*.tfstate
terraform/*.tfstate.backup
terraform/*.tfvars

# Go
blog/blog

# OS
.DS_Store
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: add .gitignore for terraform, go, and os files"
```

---

### Task 2: Go Module & Dependencies

**Files:**
- Create: `blog/go.mod`
- Create: `blog/go.sum` (auto-generated)

- [ ] **Step 1: Initialize Go module**

```bash
cd blog
go mod init github.com/connordavenport/dev-lab/blog
```

- [ ] **Step 2: Add dependencies**

```bash
cd blog
go get github.com/yuin/goldmark@latest
go get gopkg.in/yaml.v3@latest
```

- [ ] **Step 3: Verify go.mod looks correct**

```bash
cat blog/go.mod
```

Expected: module path, Go version, require block with goldmark and yaml.v3.

- [ ] **Step 4: Commit**

```bash
git add blog/go.mod blog/go.sum
git commit -m "chore: initialize go module with goldmark and yaml dependencies"
```

---

### Task 3: Post Parsing — Failing Tests

**Files:**
- Create: `blog/post.go`
- Create: `blog/post_test.go`
- Create: `blog/testdata/valid-post.md`

- [ ] **Step 1: Create a test fixture markdown post**

Create `blog/testdata/valid-post.md`:

```markdown
---
title: "Test Post"
date: 2026-01-15
tags: ["go", "test"]
slug: "test-post"
---

This is a **test** post with some markdown.

- Item one
- Item two
```

- [ ] **Step 2: Write the Post struct and function signatures (empty)**

Create `blog/post.go`:

```go
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
```

Note: imports are minimal here so the stub compiles. Full imports are added in Task 4 when implementing.

- [ ] **Step 3: Write tests for ParsePost**

Create `blog/post_test.go`:

```go
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
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
cd blog && go test -v -run TestParsePost
```

Expected: FAIL — "not implemented"

- [ ] **Step 5: Commit**

```bash
git add blog/post.go blog/post_test.go blog/testdata/
git commit -m "test: add failing tests for post parsing"
```

---

### Task 4: Post Parsing — Implementation

**Files:**
- Modify: `blog/post.go` (implement ParsePost and LoadPosts)
- Create: `blog/testdata/second-post.md` (for LoadPosts test)

- [ ] **Step 1: Implement ParsePost**

First, update the imports in `blog/post.go` to include everything needed:

```go
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
```

Then replace the `ParsePost` function in `blog/post.go`:

```go
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
```

- [ ] **Step 2: Run ParsePost tests**

```bash
cd blog && go test -v -run TestParsePost
```

Expected: PASS for `TestParsePost` and `TestParsePostMissingFile`.

- [ ] **Step 3: Create second test fixture for LoadPosts**

Create `blog/testdata/second-post.md`:

```markdown
---
title: "Second Post"
date: 2026-02-20
tags: ["updates"]
slug: "second-post"
---

A second post for testing load order.
```

- [ ] **Step 4: Add LoadPosts test to post_test.go**

Append to `blog/post_test.go`:

```go
func TestLoadPosts(t *testing.T) {
	posts, err := LoadPosts("testdata")
	if err != nil {
		t.Fatalf("LoadPosts returned error: %v", err)
	}
	if len(posts) != 2 {
		t.Fatalf("got %d posts, want 2", len(posts))
	}
	// Should be sorted by date descending — second-post (Feb) before valid-post (Jan).
	if posts[0].Slug != "second-post" {
		t.Errorf("first post slug = %q, want %q", posts[0].Slug, "second-post")
	}
	if posts[1].Slug != "test-post" {
		t.Errorf("second post slug = %q, want %q", posts[1].Slug, "test-post")
	}
}
```

- [ ] **Step 5: Implement LoadPosts**

Replace the `LoadPosts` function in `blog/post.go`:

```go
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
```

- [ ] **Step 6: Run all tests**

```bash
cd blog && go test -v
```

Expected: all PASS.

- [ ] **Step 7: Commit**

```bash
git add blog/post.go blog/post_test.go blog/testdata/
git commit -m "feat: implement markdown post parsing with frontmatter support"
```

---

### Task 5: HTTP Handlers — Failing Tests

**Files:**
- Create: `blog/handler.go`
- Create: `blog/handler_test.go`

- [ ] **Step 1: Write handler signatures (empty)**

Create `blog/handler.go`:

```go
package main

import (
	"fmt"
	"html/template"
	"net/http"
)

type Server struct {
	posts     []Post
	templates *template.Template
}

func NewServer(postsDir, templatesDir string) (*Server, error) {
	return nil, fmt.Errorf("not implemented")
}

func (s *Server) HandleIndex(w http.ResponseWriter, r *http.Request) {
	http.Error(w, "not implemented", http.StatusInternalServerError)
}

func (s *Server) HandlePost(w http.ResponseWriter, r *http.Request) {
	http.Error(w, "not implemented", http.StatusInternalServerError)
}
```

- [ ] **Step 2: Write handler tests**

Create `blog/handler_test.go`:

```go
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
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
cd blog && go test -v -run TestHandle
```

Expected: FAIL — "not implemented"

- [ ] **Step 4: Commit**

```bash
git add blog/handler.go blog/handler_test.go
git commit -m "test: add failing tests for HTTP handlers"
```

---

### Task 6: Templates & Static Assets

**Files:**
- Create: `blog/templates/layout.html`
- Create: `blog/templates/index.html`
- Create: `blog/templates/post.html`
- Create: `blog/static/style.css`
- Create: `blog/testdata/templates/layout.html` (minimal test version)
- Create: `blog/testdata/templates/index.html`
- Create: `blog/testdata/templates/post.html`

- [ ] **Step 1: Create test templates (minimal, for handler tests)**

Create `blog/testdata/templates/layout.html`:

```html
{{define "layout"}}<!DOCTYPE html>
<html><head><title>Test</title></head>
<body>{{template "content" .}}</body>
</html>{{end}}
```

Create `blog/testdata/templates/index.html`:

```html
{{define "content"}}
{{range .Posts}}<h2>{{.Title}}</h2>
{{end}}
{{end}}
```

Create `blog/testdata/templates/post.html`:

```html
{{define "content"}}
<h1>{{.Post.Title}}</h1>
<div>{{.Post.Content}}</div>
{{end}}
```

- [ ] **Step 2: Create production templates**

Create `blog/templates/layout.html`:

```html
{{define "layout"}}<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{{if .Title}}{{.Title}} — {{end}}cdavenport.io</title>
    <link rel="stylesheet" href="/static/style.css">
</head>
<body>
    <nav>
        <a href="/">cdavenport.io</a>
    </nav>
    <main>
        {{template "content" .}}
    </main>
    <footer>
        <p>&copy; 2026 Connor Davenport</p>
    </footer>
</body>
</html>{{end}}
```

Create `blog/templates/index.html`:

```html
{{define "content"}}
<h1>Posts</h1>
{{range .Posts}}
<article>
    <h2><a href="/posts/{{.Slug}}">{{.Title}}</a></h2>
    <time datetime="{{.Date.Format "2006-01-02"}}">{{.Date.Format "January 2, 2006"}}</time>
</article>
{{end}}
{{end}}
```

Create `blog/templates/post.html`:

```html
{{define "content"}}
<article>
    <h1>{{.Post.Title}}</h1>
    <time datetime="{{.Post.Date.Format "2006-01-02"}}">{{.Post.Date.Format "January 2, 2006"}}</time>
    <div class="post-content">{{.Post.Content}}</div>
</article>
{{end}}
```

- [ ] **Step 3: Create minimal CSS**

Create `blog/static/style.css`:

```css
* {
    margin: 0;
    padding: 0;
    box-sizing: border-box;
}

body {
    font-family: system-ui, -apple-system, sans-serif;
    line-height: 1.6;
    max-width: 700px;
    margin: 0 auto;
    padding: 2rem 1rem;
    color: #222;
}

nav {
    margin-bottom: 2rem;
    padding-bottom: 1rem;
    border-bottom: 1px solid #ddd;
}

nav a {
    font-weight: bold;
    text-decoration: none;
    color: #222;
}

h1, h2 {
    margin-bottom: 0.5rem;
}

article {
    margin-bottom: 2rem;
}

article a {
    color: #222;
    text-decoration: none;
}

article a:hover {
    text-decoration: underline;
}

time {
    color: #666;
    font-size: 0.9rem;
}

.post-content {
    margin-top: 1.5rem;
}

.post-content p {
    margin-bottom: 1rem;
}

.post-content ul, .post-content ol {
    margin-bottom: 1rem;
    padding-left: 1.5rem;
}

.post-content code {
    background: #f4f4f4;
    padding: 0.15rem 0.3rem;
    border-radius: 3px;
    font-size: 0.9em;
}

.post-content pre {
    background: #f4f4f4;
    padding: 1rem;
    border-radius: 5px;
    overflow-x: auto;
    margin-bottom: 1rem;
}

.post-content pre code {
    background: none;
    padding: 0;
}

footer {
    margin-top: 3rem;
    padding-top: 1rem;
    border-top: 1px solid #ddd;
    color: #666;
    font-size: 0.85rem;
}
```

- [ ] **Step 4: Commit**

```bash
git add blog/templates/ blog/static/ blog/testdata/templates/
git commit -m "feat: add HTML templates and CSS for blog"
```

---

### Task 7: HTTP Handlers — Implementation

**Files:**
- Modify: `blog/handler.go` (implement NewServer, HandleIndex, HandlePost)
- Modify: `blog/handler_test.go` (no changes expected, just run)

- [ ] **Step 1: Implement handlers**

Replace the full contents of `blog/handler.go`:

```go
package main

import (
	"fmt"
	"html/template"
	"net/http"
	"strings"
)

type Server struct {
	posts     []Post
	templates *template.Template
}

func NewServer(postsDir, templatesDir string) (*Server, error) {
	posts, err := LoadPosts(postsDir)
	if err != nil {
		return nil, fmt.Errorf("loading posts: %w", err)
	}

	tmpl, err := template.New("").Funcs(template.FuncMap{
		"safeHTML": func(s string) template.HTML { return template.HTML(s) },
	}).ParseGlob(templatesDir + "/*.html")
	if err != nil {
		return nil, fmt.Errorf("parsing templates: %w", err)
	}

	return &Server{posts: posts, templates: tmpl}, nil
}

func (s *Server) HandleIndex(w http.ResponseWriter, r *http.Request) {
	data := map[string]any{
		"Title": "",
		"Posts": s.posts,
	}
	if err := s.templates.ExecuteTemplate(w, "layout", data); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}

func (s *Server) HandlePost(w http.ResponseWriter, r *http.Request) {
	slug := strings.TrimPrefix(r.URL.Path, "/posts/")

	for _, p := range s.posts {
		if p.Slug == slug {
			data := map[string]any{
				"Title": p.Title,
				"Post":  p,
			}
			if err := s.templates.ExecuteTemplate(w, "layout", data); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
			}
			return
		}
	}

	http.NotFound(w, r)
}
```

- [ ] **Step 2: Update test templates to use safeHTML**

Update `blog/testdata/templates/post.html` to render HTML content properly:

```html
{{define "content"}}
<h1>{{.Post.Title}}</h1>
<div>{{safeHTML .Post.Content}}</div>
{{end}}
```

Also update `blog/templates/post.html`:

```html
{{define "content"}}
<article>
    <h1>{{.Post.Title}}</h1>
    <time datetime="{{.Post.Date.Format "2006-01-02"}}">{{.Post.Date.Format "January 2, 2006"}}</time>
    <div class="post-content">{{safeHTML .Post.Content}}</div>
</article>
{{end}}
```

- [ ] **Step 3: Run all tests**

```bash
cd blog && go test -v
```

Expected: all PASS (ParsePost, LoadPosts, HandleIndex, HandlePost, HandlePostNotFound).

- [ ] **Step 4: Commit**

```bash
git add blog/handler.go blog/testdata/templates/ blog/templates/
git commit -m "feat: implement HTTP handlers for index and post pages"
```

---

### Task 8: Main Entry Point & Sample Post

**Files:**
- Create: `blog/main.go`
- Create: `blog/posts/hello-world.md`

- [ ] **Step 1: Create main.go**

Create `blog/main.go`:

```go
package main

import (
	"embed"
	"io/fs"
	"log"
	"net/http"
)

//go:embed static
var staticFiles embed.FS

func main() {
	srv, err := NewServer("posts", "templates")
	if err != nil {
		log.Fatal(err)
	}

	staticFS, err := fs.Sub(staticFiles, "static")
	if err != nil {
		log.Fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", srv.HandleIndex)
	mux.HandleFunc("/posts/", srv.HandlePost)
	mux.Handle("/static/", http.StripPrefix("/static/", http.FileServer(http.FS(staticFS))))

	log.Println("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", mux))
}
```

- [ ] **Step 2: Create sample blog post**

Create `blog/posts/hello-world.md`:

```markdown
---
title: "Hello, World"
date: 2026-04-14
tags: ["meta"]
slug: "hello-world"
---

Welcome to my blog. This site is served from a DigitalOcean droplet, provisioned with Terraform, configured with cloud-init, and running a Go server behind Caddy.

The source code is fully reproducible — a single `terraform apply` rebuilds everything from scratch.
```

- [ ] **Step 3: Build and run locally**

```bash
cd blog && go build -o blog . && ./blog
```

Visit `http://localhost:8080` — should see the post listing.
Visit `http://localhost:8080/posts/hello-world` — should see the full post.

Stop the server with Ctrl+C.

- [ ] **Step 4: Commit**

```bash
git add blog/main.go blog/posts/
git commit -m "feat: add main entry point and sample blog post"
```

---

### Task 9: Dockerfile

**Files:**
- Create: `blog/Dockerfile`

- [ ] **Step 1: Create multi-stage Dockerfile**

Create `blog/Dockerfile`:

```dockerfile
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /blog .

FROM alpine:3.20
RUN adduser -D -u 1000 appuser
COPY --from=build /blog /blog
COPY posts/ /data/posts/
COPY templates/ /data/templates/
WORKDIR /data
USER appuser
EXPOSE 8080
CMD ["/blog"]
```

- [ ] **Step 2: Build the image locally**

```bash
cd blog && docker build -t blog:test .
```

Expected: successful build, small final image.

- [ ] **Step 3: Run and test locally**

```bash
docker run --rm -p 8080:8080 blog:test
```

Visit `http://localhost:8080` — should show the blog.

Stop with Ctrl+C.

- [ ] **Step 4: Commit**

```bash
git add blog/Dockerfile
git commit -m "feat: add multi-stage Dockerfile for blog"
```

---

### Task 10: Docker Compose & Caddyfile

**Files:**
- Create: `docker-compose.yml`
- Create: `Caddyfile`

- [ ] **Step 1: Create Caddyfile**

Create `Caddyfile`:

```
cdavenport.io {
    reverse_proxy blog:8080
}

www.cdavenport.io {
    redir https://cdavenport.io{uri} permanent
}
```

- [ ] **Step 2: Create docker-compose.yml**

Create `docker-compose.yml`:

```yaml
services:
  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - blog

  blog:
    build: ./blog
    restart: unless-stopped
    expose:
      - "8080"

volumes:
  caddy_data:
  caddy_config:
```

- [ ] **Step 3: Create a local-testing Caddyfile override**

Create `Caddyfile.local` for testing without a real domain:

```
:80 {
    reverse_proxy blog:8080
}
```

Test locally:

```bash
cp Caddyfile Caddyfile.bak && cp Caddyfile.local Caddyfile
docker compose up --build
```

Visit `http://localhost` — should show the blog via Caddy.

Stop with Ctrl+C, then restore:

```bash
mv Caddyfile.bak Caddyfile
```

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml Caddyfile Caddyfile.local
git commit -m "feat: add docker compose stack with caddy reverse proxy"
```

---

### Task 11: Terraform Variables & Provider

**Files:**
- Create: `terraform/variables.tf`
- Create: `terraform/main.tf` (provider block only)
- Create: `terraform/terraform.tfvars.example`

- [ ] **Step 1: Create variables.tf**

Create `terraform/variables.tf`:

```hcl
variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "ssh_key_name" {
  description = "Name of the SSH key in DigitalOcean"
  type        = string
}

variable "droplet_region" {
  description = "DigitalOcean region slug"
  type        = string
  default     = "nyc1"
}

variable "droplet_size" {
  description = "DigitalOcean droplet size slug"
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "droplet_image" {
  description = "DigitalOcean droplet image slug"
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "domain" {
  description = "Domain name"
  type        = string
  default     = "cdavenport.io"
}

variable "username" {
  description = "Non-root user to create on the server"
  type        = string
  default     = "connor"
}

variable "ssh_port" {
  description = "Custom SSH port"
  type        = number
  default     = 2222
}

variable "repo_url" {
  description = "Git repo URL to clone on the server"
  type        = string
}
```

- [ ] **Step 2: Create provider block in main.tf**

Create `terraform/main.tf`:

```hcl
terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

data "digitalocean_ssh_key" "main" {
  name = var.ssh_key_name
}
```

- [ ] **Step 3: Create tfvars example**

Create `terraform/terraform.tfvars.example`:

```hcl
do_token     = "your-digitalocean-api-token"
ssh_key_name = "your-ssh-key-name"
repo_url     = "https://github.com/connordavenport/dev-lab.git"
# droplet_region = "nyc1"
# droplet_size   = "s-1vcpu-1gb"
# username       = "connor"
```

- [ ] **Step 4: Validate syntax**

```bash
cd terraform && terraform init && terraform validate
```

Expected: "Success! The configuration is valid."

- [ ] **Step 5: Commit**

```bash
git add terraform/variables.tf terraform/main.tf terraform/terraform.tfvars.example
git commit -m "feat: add terraform provider config and variables"
```

---

### Task 12: Cloud-Init Template

**Files:**
- Create: `terraform/cloud-init.yml.tpl`

- [ ] **Step 1: Create cloud-init template**

Create `terraform/cloud-init.yml.tpl`:

```yaml
#cloud-config

users:
  - name: ${username}
    groups: sudo, docker
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${ssh_public_key}

package_update: true
package_upgrade: true

packages:
  - ufw
  - fail2ban
  - unattended-upgrades
  - apt-transport-https
  - ca-certificates
  - curl
  - gnupg
  - git

runcmd:
  # SSH hardening
  - sed -i 's/^#\?Port .*/Port ${ssh_port}/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
  - systemctl restart sshd

  # UFW firewall
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow ${ssh_port}/tcp
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - ufw --force enable

  # Fail2ban for SSH
  - |
    cat > /etc/fail2ban/jail.local << 'JAIL'
    [sshd]
    enabled = true
    port = ${ssh_port}
    filter = sshd
    logpath = /var/log/auth.log
    maxretry = 5
    bantime = 3600
    JAIL
  - systemctl enable fail2ban
  - systemctl restart fail2ban

  # Enable unattended upgrades
  - |
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'APT'
    APT::Periodic::Update-Package-Lists "1";
    APT::Periodic::Unattended-Upgrade "1";
    APT

  # Install Docker
  - install -m 0755 -d /etc/apt/keyrings
  - curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  - chmod a+r /etc/apt/keyrings/docker.asc
  - |
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/docker.list
  - apt-get update
  - apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  # Clone repo and start services
  - git clone ${repo_url} /home/${username}/dev-lab
  - chown -R ${username}:${username} /home/${username}/dev-lab
  - cd /home/${username}/dev-lab && docker compose up -d
```

- [ ] **Step 2: Commit**

```bash
git add terraform/cloud-init.yml.tpl
git commit -m "feat: add cloud-init template for server hardening and docker setup"
```

---

### Task 13: Terraform Resources (Droplet, DNS, Firewall)

**Files:**
- Modify: `terraform/main.tf` (add resources)
- Create: `terraform/outputs.tf`

- [ ] **Step 1: Add resources to main.tf**

Append the following to `terraform/main.tf` after the provider and data blocks:

```hcl
resource "digitalocean_droplet" "web" {
  name     = "dev-lab"
  image    = var.droplet_image
  size     = var.droplet_size
  region   = var.droplet_region
  ssh_keys = [data.digitalocean_ssh_key.main.id]

  user_data = templatefile("${path.module}/cloud-init.yml.tpl", {
    username       = var.username
    ssh_public_key = data.digitalocean_ssh_key.main.public_key
    ssh_port       = var.ssh_port
    repo_url       = var.repo_url
  })

  tags = ["dev-lab"]
}

# DNS
resource "digitalocean_domain" "main" {
  name       = var.domain
  ip_address = digitalocean_droplet.web.ipv4_address
}

resource "digitalocean_record" "www" {
  domain = digitalocean_domain.main.id
  type   = "A"
  name   = "www"
  value  = digitalocean_droplet.web.ipv4_address
  ttl    = 3600
}

# Cloud firewall
resource "digitalocean_firewall" "web" {
  name        = "dev-lab-firewall"
  droplet_ids = [digitalocean_droplet.web.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = tostring(var.ssh_port)
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}
```

- [ ] **Step 2: Create outputs.tf**

Create `terraform/outputs.tf`:

```hcl
output "droplet_ip" {
  description = "Public IPv4 address of the droplet"
  value       = digitalocean_droplet.web.ipv4_address
}

output "domain" {
  description = "Domain name"
  value       = var.domain
}

output "ssh_command" {
  description = "SSH command to connect"
  value       = "ssh -p ${var.ssh_port} ${var.username}@${digitalocean_droplet.web.ipv4_address}"
}

output "nameservers" {
  description = "Set these nameservers at your domain registrar"
  value       = "ns1.digitalocean.com, ns2.digitalocean.com, ns3.digitalocean.com"
}
```

- [ ] **Step 3: Validate terraform**

```bash
cd terraform && terraform validate
```

Expected: "Success! The configuration is valid."

- [ ] **Step 4: Review the plan (dry run, no apply)**

```bash
cd terraform && terraform plan -var-file=terraform.tfvars
```

This requires a real `terraform.tfvars` with your DO token and SSH key name. Review the output — it should show creation of: 1 droplet, 1 domain, 1 DNS record (www), 1 firewall. The apex A record is created automatically by the `digitalocean_domain` resource's `ip_address` argument.

- [ ] **Step 5: Commit**

```bash
git add terraform/main.tf terraform/outputs.tf
git commit -m "feat: add terraform resources for droplet, DNS, and firewall"
```

---

### Task 14: Deploy & Verify

**Files:** None — this is an operational task.

**Prerequisites before this task:**
- GitHub repo created and all code pushed
- `terraform/terraform.tfvars` created from the example (not committed — it's in .gitignore)
- Nameservers at Squarespace changed to DigitalOcean's (do this before or right after apply; DNS propagation takes minutes to hours)

- [ ] **Step 1: Push all code to GitHub**

```bash
git remote add origin <your-github-repo-url>
git push -u origin main
```

- [ ] **Step 2: Create terraform.tfvars**

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars` with real values.

- [ ] **Step 3: Apply Terraform**

```bash
cd terraform && terraform apply
```

Review the plan, type `yes`. Note the outputs — droplet IP, SSH command, nameserver reminder.

- [ ] **Step 4: Wait for cloud-init to complete**

Cloud-init takes a few minutes. Check status:

```bash
ssh -p 2222 connor@<droplet-ip> "cloud-init status --wait"
```

Expected: `status: done`

- [ ] **Step 5: Verify Docker stack is running**

```bash
ssh -p 2222 connor@<droplet-ip> "docker compose -f ~/dev-lab/docker-compose.yml ps"
```

Expected: both `caddy` and `blog` services running.

- [ ] **Step 6: Verify HTTPS**

Once DNS has propagated:

```bash
curl -I https://cdavenport.io
```

Expected: HTTP 200, valid TLS certificate.

```bash
curl -I https://www.cdavenport.io
```

Expected: HTTP 301 redirect to `https://cdavenport.io`.

- [ ] **Step 7: Visit in browser**

Open `https://cdavenport.io` — should show the blog with the "Hello, World" post.

- [ ] **Step 8: Commit terraform lock file**

After `terraform init` creates `.terraform.lock.hcl`:

```bash
git add terraform/.terraform.lock.hcl
git commit -m "chore: add terraform lock file for reproducibility"
```
