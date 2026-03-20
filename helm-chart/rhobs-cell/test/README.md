# Thanos Receive Test

Simple Go script to test sending metrics to Thanos Receive.

## Prerequisites

- Go 1.21+
- Thanos Receive running and accessible

## Quick Start

### 1. Deploy Thanos Receive

```bash
# From the helm-chart/rhobs-cell directory
helm dependency update
helm install thanos-test . -f values-test-receive.yaml -n thanos-test --create-namespace

# Wait for pods
kubectl get pods -n thanos-test -w
```

### 2. Port-forward to Thanos Receive

```bash
kubectl port-forward svc/thanos-test-thanos-receive 19291:19291 -n thanos-test
```

### 3. Run the test

```bash
cd test
go mod tidy
go run main.go
```

### 4. Verify the metric

```bash
# Port-forward to Thanos Query
kubectl port-forward svc/thanos-test-thanos-query 9090:9090 -n thanos-test

# Query the metric
curl -s 'http://localhost:9090/api/v1/query?query=test_metric' | jq .
```

## Options

```bash
# Send with custom metric name and value
go run main.go --metric my_custom_metric --value 123.45

# Send to different endpoint
go run main.go --endpoint http://thanos-receive.example.com:19291/api/v1/receive
```

## Expected Output

Success:
```
✓ Successfully sent metric!
  Metric: test_metric{job="thanos-receive-test"} 42
  Endpoint: http://localhost:19291/api/v1/receive
  Status: 200 OK
```

Query result:
```json
{
  "status": "success",
  "data": {
    "resultType": "vector",
    "result": [
      {
        "metric": {
          "__name__": "test_metric",
          "cluster": "test-cluster",
          "instance": "test-instance",
          "job": "thanos-receive-test",
          "region": "us-east-1"
        },
        "value": [1710936000, "42"]
      }
    ]
  }
}
```

## Cleanup

```bash
helm uninstall thanos-test -n thanos-test
kubectl delete namespace thanos-test
```
