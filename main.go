package main

import (
	"bufio"
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"cloud.google.com/go/storage"
)

func main() {
	numWorkers := 10
	if n, err := strconv.Atoi(os.Getenv("NUM_WORKERS")); err == nil {
		numWorkers = n
	}
	endpoints := []string{
		"http://http-service.default.svc.cluster.local/snowpipe/insert/BENTHOS_DB/PUBLIC/TABLE_A",
		"http://http-service.default.svc.cluster.local/snowpipe/insert/BENTHOS_DB/PUBLIC/TABLE_B",
		"http://http-service.default.svc.cluster.local/snowpipe/insert/BENTHOS_DB/PUBLIC/TABLE_C",
		"http://http-service.default.svc.cluster.local/snowpipe/insert/BENTHOS_DB/PUBLIC/TABLE_D",
		"http://http-service.default.svc.cluster.local/snowpipe/insert/BENTHOS_DB/PUBLIC/TABLE_E",
		"http://http-service.default.svc.cluster.local/snowpipe/insert/BENTHOS_DB/PUBLIC/TABLE_F",
		"http://http-service.default.svc.cluster.local/snowpipe/insert/BENTHOS_DB/PUBLIC/TABLE_G",
		"http://http-service.default.svc.cluster.local/snowpipe/insert/BENTHOS_DB/PUBLIC/TABLE_H",
		"http://http-service.default.svc.cluster.local/snowpipe/insert/BENTHOS_DB/PUBLIC/TABLE_I",
		"http://http-service.default.svc.cluster.local/snowpipe/insert/BENTHOS_DB/PUBLIC/TABLE_J",
	}

	log.Println("downloading data file")
	dataFile, err := downloadFile("rp-byoc-tyler-k8s-serving", "data.jsonl")
	if err != nil {
		log.Fatalf("cannot read data file: %v", err)
	}
	log.Println("parsing data file")
	scanner := bufio.NewScanner(bytes.NewBuffer(dataFile))
	var datas []any
	for scanner.Scan() {
		var entry any
		if err := json.Unmarshal(scanner.Bytes(), &entry); err != nil {
			log.Fatalf("Invalid JSONL entry: %v", err)
		}
		datas = append(datas, entry)
	}
	if err := scanner.Err(); err != nil {
		log.Fatalf("Error reading file: %v", err)
	}
	// Handle graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, os.Interrupt, syscall.SIGTERM)
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		<-sigChan
		log.Println("Received shutdown signal, exiting...")
		cancel()
	}()
	log.Printf("starting up %d workers to generate load...\n", numWorkers)
	var count atomic.Int64
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-t.C:
			case <-ctx.Done():
				return
			}
			log.Printf("QPS: %.2f/s\n", float64(count.Swap(0))/30.0)
		}
	}()
	for i := range numWorkers {
		wg.Add(1)
		i := i
		go func() {
			defer wg.Done()
			log.Println("worker", i, "starting")
			defer log.Println("worker", i, "exiting")
			for ctx.Err() == nil {
				e := selectEndpoint(endpoints)
				data := selectRandomEntries(datas)
				postData(ctx, e, data)
				count.Add(1)
			}
		}()
	}
	wg.Wait()
	log.Println("Finished generating load. Shutting down.")
}

func selectEndpoint(endpoints []string) string {
	if rand.Float64() < 0.8 {
		return endpoints[0]
	}
	return endpoints[rand.Intn(len(endpoints)-1)+1]
}

func selectRandomEntries(entries []any) []any {
	n := rand.Intn(6) + 5 // Select 5 to 10 entries
	var batch []any
	for i := 0; i < n && len(entries) > 0; i++ {
		idx := rand.Intn(len(entries))
		batch = append(batch, entries[idx])
		entries = append(entries[:idx], entries[idx+1:]...)
	}
	return batch
}

func downloadFile(bucketName, objectName string) ([]byte, error) {
	ctx := context.Background()
	// Initialize GCS client with credentials
	client, err := storage.NewClient(ctx)
	if err != nil {
		return nil, err
	}
	defer client.Close()

	// Get bucket and object handle
	bucket := client.Bucket(bucketName)
	object := bucket.Object(objectName)
	reader, err := object.NewReader(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to open file: %w", err)
	}
	defer reader.Close()
	return io.ReadAll(reader)
}

var client = http.Client{
	Transport: &http.Transport{
		DisableKeepAlives:   true,
		DisableCompression:  true,
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 100,
		MaxConnsPerHost:     100,
		IdleConnTimeout:     10 * time.Second,
	},
	Timeout: 10 * time.Second,
}

func postData(ctx context.Context, endpoint string, data any) {
	jsonData, err := json.Marshal(data)
	if err != nil {
		log.Fatalf("Error marshalling JSON: %v", err)
	}
	req, err := http.NewRequestWithContext(ctx, "POST", endpoint, bytes.NewBuffer(jsonData))
	if err != nil {
		log.Printf("Failed to make POST request: %v", err)
		return
	}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("Failed to post data: %v", err)
		return
	}
	defer resp.Body.Close()
	_, err = io.Copy(io.Discard, resp.Body)
	if err != nil {
		log.Printf("Failed to read response: %v", err)
		return
	}
	if resp.StatusCode != 200 {
		log.Println("failed status code (%v)", resp.StatusCode)
	}
}
