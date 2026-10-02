// ORACLE for yamlvalue's `helm` profile (cartograph tools/oraclejoin.lua `yaml:helm`): HELM'S OWN VALUES LOADER —
// sigs.k8s.io/yaml.Unmarshal into a map, exactly helm pkg/chart/common/values.go ReadValues (go.yaml.in/yaml/v2, then a
// JSON round trip) — over each NUL-separated path on stdin. Prints the joiner's wire: {path: {value: {"__a": [doc]}}}
// with every scalar "type:value" (null, bool, number as %.17g, str) and keys "str:<key>" (JSON keys are strings).
// Only the FIRST document is read, as Helm reads a values file; no document (empty, comments) is an empty stream.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"sort"
	"strings"

	"sigs.k8s.io/yaml"
)

func canon(v interface{}) interface{} {
	switch x := v.(type) {
	case map[string]interface{}:
		keys := make([]string, 0, len(x))
		for k := range x {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		pairs := make([][]interface{}, 0, len(keys))
		for _, k := range keys {
			pairs = append(pairs, []interface{}{"str:" + k, canon(x[k])})
		}
		return map[string]interface{}{"__o": pairs}
	case []interface{}:
		a := make([]interface{}, len(x))
		for i, e := range x {
			a[i] = canon(e)
		}
		return map[string]interface{}{"__a": a}
	case nil:
		return "null"
	case bool:
		return fmt.Sprintf("bool:%v", x)
	case float64:
		switch {
		case math.IsNaN(x):
			return "number:nan"
		case math.IsInf(x, 1):
			return "number:inf"
		case math.IsInf(x, -1):
			return "number:-inf"
		case x == 0 && math.Signbit(x):
			return "number:-0"
		}
		return fmt.Sprintf("number:%.17g", x)
	case string:
		return "str:" + x
	}
	return fmt.Sprintf("unknown:%T", v)
}

func main() {
	all, _ := io.ReadAll(os.Stdin)
	out := map[string]interface{}{}
	for _, p := range strings.Split(string(all), "\x00") {
		if p == "" {
			continue
		}
		b, err := os.ReadFile(p)
		if err != nil {
			out[p] = map[string]interface{}{"error": err.Error()}
			continue
		}
		var v map[string]interface{}
		if err := yaml.Unmarshal(b, &v); err != nil {
			out[p] = map[string]interface{}{"error": strings.ReplaceAll(err.Error(), "\n", " ")}
			continue
		}
		docs := []interface{}{}
		if v != nil {
			docs = append(docs, canon(v))
		}
		out[p] = map[string]interface{}{"value": map[string]interface{}{"__a": docs}}
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	enc.Encode(out)
}
