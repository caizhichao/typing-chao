package main

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const maxBodyBytes = 128 * 1024

type rateEntry struct {
	startedAt time.Time
	count     int
}

type proxyServer struct {
	client         *http.Client
	upstreamURL    string
	deepSeekAPIKey string
	accessToken    string
	limiter        sync.Mutex
	rateByIP       map[string]rateEntry
}

func main() {
	server := &proxyServer{
		client:         &http.Client{Timeout: 30 * time.Second},
		upstreamURL:    requiredEnv("TYPING_DONGNANYA_DEEPSEEK_API_URL"),
		deepSeekAPIKey: requiredEnv("TYPING_DONGNANYA_DEEPSEEK_API_KEY"),
		accessToken:    requiredEnv("TYPING_DONGNANYA_ACCESS_TOKEN"),
		rateByIP:       make(map[string]rateEntry),
	}
	listenHost := envOrDefault("TYPING_DONGNANYA_LISTEN_HOST", "127.0.0.1")
	listenPort := envOrDefault("TYPING_DONGNANYA_LISTEN_PORT", "18127")
	log.Printf("TypingDongnanya Go API listening on %s:%s", listenHost, listenPort)
	if err := http.ListenAndServe(listenHost+":"+listenPort, server.routes()); err != nil {
		log.Fatal(err)
	}
}

// routes 将健康检查与受限 completion 路由集中，保证本地测试和线上入口使用同一套匹配规则。
func (server *proxyServer) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", server.handleHealth)
	mux.HandleFunc("/v1/chat/completions", server.handleMissingCompletion)
	mux.HandleFunc("/v1/chat/completions/", server.handleCompletion)
	return http.MaxBytesHandler(mux, maxBodyBytes)
}

func (server *proxyServer) handleHealth(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeJSON(response, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	writeJSON(response, http.StatusOK, map[string]string{"status": "ok"})
}

// 缺少 capability 的标准 completion 路径直接返回 404，不由 ServeMux 重定向到可枚举的尾斜杠路由。
func (server *proxyServer) handleMissingCompletion(response http.ResponseWriter, request *http.Request) {
	writeJSON(response, http.StatusNotFound, map[string]string{"error": "not_found"})
}

func (server *proxyServer) handleCompletion(response http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost || !server.hasValidToken(request.URL.Path) {
		writeJSON(response, http.StatusNotFound, map[string]string{"error": "not_found"})
		return
	}
	if !server.allowRequest(request.RemoteAddr) {
		writeJSON(response, http.StatusTooManyRequests, map[string]string{"error": "rate_limit_exceeded"})
		return
	}
	body, err := io.ReadAll(request.Body)
	if err != nil {
		writeJSON(response, http.StatusBadRequest, map[string]string{"error": "invalid_request_body"})
		return
	}
	upstreamRequest, err := http.NewRequestWithContext(request.Context(), http.MethodPost, strings.TrimRight(server.upstreamURL, "/")+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		writeJSON(response, http.StatusBadGateway, map[string]string{"error": "upstream_unavailable"})
		return
	}
	upstreamRequest.Header.Set("Accept", "application/json")
	upstreamRequest.Header.Set("Authorization", "Bearer "+server.deepSeekAPIKey)
	upstreamRequest.Header.Set("Cache-Control", "no-store")
	upstreamRequest.Header.Set("Content-Type", "application/json")
	upstreamResponse, err := server.client.Do(upstreamRequest)
	if err != nil {
		log.Printf("upstream translation request failed: %v", err)
		writeJSON(response, http.StatusBadGateway, map[string]string{"error": "upstream_unavailable"})
		return
	}
	defer upstreamResponse.Body.Close()
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("Content-Type", upstreamResponse.Header.Get("Content-Type"))
	response.Header().Set("X-Content-Type-Options", "nosniff")
	response.WriteHeader(upstreamResponse.StatusCode)
	if _, err := io.Copy(response, upstreamResponse.Body); err != nil {
		log.Printf("response copy failed: %v", err)
	}
}

func (server *proxyServer) hasValidToken(path string) bool {
	prefix := "/v1/chat/completions/"
	if !strings.HasPrefix(path, prefix) {
		return false
	}
	actualToken := strings.TrimSuffix(strings.TrimPrefix(path, prefix), "/")
	return len(actualToken) == len(server.accessToken) && subtle.ConstantTimeCompare([]byte(actualToken), []byte(server.accessToken)) == 1
}

func (server *proxyServer) allowRequest(remoteAddress string) bool {
	ip := remoteAddress
	if host, _, splitErr := strings.Cut(remoteAddress, ":"); splitErr {
		ip = host
	}
	now := time.Now()
	server.limiter.Lock()
	defer server.limiter.Unlock()
	entry, exists := server.rateByIP[ip]
	if !exists || now.Sub(entry.startedAt) >= time.Minute {
		server.rateByIP[ip] = rateEntry{startedAt: now, count: 1}
		return true
	}
	if entry.count >= 30 {
		return false
	}
	entry.count++
	server.rateByIP[ip] = entry
	return true
}

func writeJSON(response http.ResponseWriter, status int, value any) {
	response.Header().Set("Content-Type", "application/json; charset=utf-8")
	response.Header().Set("X-Content-Type-Options", "nosniff")
	response.WriteHeader(status)
	_ = json.NewEncoder(response).Encode(value)
}

func requiredEnv(name string) string {
	value := os.Getenv(name)
	if value == "" {
		log.Fatalf("missing required environment variable: %s", name)
	}
	return value
}

func envOrDefault(name string, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
