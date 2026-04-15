package main

import (
	"fmt"
	"html/template"
	"net/http"
	"strings"
)

type Server struct {
	posts         []Post
	indexTemplate *template.Template
	postTemplate  *template.Template
}

func newTemplatePair(layoutFile, contentFile string) (*template.Template, error) {
	return template.New("").Funcs(template.FuncMap{
		"safeHTML": func(s string) template.HTML { return template.HTML(s) },
	}).ParseFiles(layoutFile, contentFile)
}

func NewServer(postsDir, templatesDir string) (*Server, error) {
	posts, err := LoadPosts(postsDir)
	if err != nil {
		return nil, fmt.Errorf("loading posts: %w", err)
	}

	indexTmpl, err := newTemplatePair(
		templatesDir+"/layout.html",
		templatesDir+"/index.html",
	)
	if err != nil {
		return nil, fmt.Errorf("parsing index template: %w", err)
	}

	postTmpl, err := newTemplatePair(
		templatesDir+"/layout.html",
		templatesDir+"/post.html",
	)
	if err != nil {
		return nil, fmt.Errorf("parsing post template: %w", err)
	}

	return &Server{posts: posts, indexTemplate: indexTmpl, postTemplate: postTmpl}, nil
}

func (s *Server) HandleIndex(w http.ResponseWriter, r *http.Request) {
	data := map[string]any{
		"Title": "",
		"Posts": s.posts,
	}
	if err := s.indexTemplate.ExecuteTemplate(w, "layout", data); err != nil {
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
			if err := s.postTemplate.ExecuteTemplate(w, "layout", data); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
			}
			return
		}
	}

	http.NotFound(w, r)
}
