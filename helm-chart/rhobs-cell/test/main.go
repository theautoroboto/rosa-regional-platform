// Test script to send a metric to Thanos Receive
// Usage: go run main.go [--endpoint http://localhost:19291]
package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/gogo/protobuf/proto"
	"github.com/golang/snappy"
	"github.com/prometheus/prometheus/prompb"
)

func main() {
	endpoint := flag.String("endpoint", "http://localhost:19291/api/v1/receive", "Thanos Receive endpoint")
	metricName := flag.String("metric", "test_metric", "Metric name to send")
	metricValue := flag.Float64("value", 42.0, "Metric value")
	flag.Parse()

	// Create a test metric
	ts := &prompb.TimeSeries{
		Labels: []prompb.Label{
			{Name: "__name__", Value: *metricName},
			{Name: "job", Value: "thanos-receive-test"},
			{Name: "instance", Value: "test-instance"},
			{Name: "cluster", Value: "test-cluster"},
			{Name: "region", Value: "us-east-1"},
		},
		Samples: []prompb.Sample{
			{
				Value:     *metricValue,
				Timestamp: time.Now().UnixMilli(),
			},
		},
	}

	// Create write request
	writeReq := &prompb.WriteRequest{
		Timeseries: []prompb.TimeSeries{*ts},
	}

	// Marshal to protobuf
	data, err := proto.Marshal(writeReq)
	if err != nil {
		log.Fatalf("Failed to marshal write request: %v", err)
	}

	// Compress with snappy
	compressed := snappy.Encode(nil, data)

	// Send request
	req, err := http.NewRequest("POST", *endpoint, bytes.NewReader(compressed))
	if err != nil {
		log.Fatalf("Failed to create request: %v", err)
	}

	req.Header.Set("Content-Type", "application/x-protobuf")
	req.Header.Set("Content-Encoding", "snappy")
	req.Header.Set("X-Prometheus-Remote-Write-Version", "0.1.0")

	// Optional: Add tenant header for multi-tenant setup
	req.Header.Set("THANOS-TENANT", "test-tenant")

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		log.Fatalf("Failed to send request: %v", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		fmt.Printf("✓ Successfully sent metric!\n")
		fmt.Printf("  Metric: %s{job=\"thanos-receive-test\"} %v\n", *metricName, *metricValue)
		fmt.Printf("  Endpoint: %s\n", *endpoint)
		fmt.Printf("  Status: %s\n", resp.Status)
	} else {
		fmt.Printf("✗ Failed to send metric\n")
		fmt.Printf("  Status: %s\n", resp.Status)
		fmt.Printf("  Body: %s\n", string(body))
	}
}
