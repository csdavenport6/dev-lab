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
