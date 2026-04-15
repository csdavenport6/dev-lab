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
