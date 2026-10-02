// ORIGINS (cartograph CART-1307): which values SOURCE supplied each effective value. Computed by HELM'S OWN merge, not
// a re-implementation of it: every source — the chart's values.yaml, each subchart's, each -f file, each --set — is
// copied with every leaf replaced by a MARKER naming the source and the path inside it (tables stay tables, nulls stay
// null: the merge only ever distinguishes those three, so it behaves identically), and the copies go through the same
// steps Helm takes (MergeMaps over the -f files in order, the --set values after, then ToRenderValues: the chart
// defaults coalesced in, nulls removing defaults, subcharts given their section and the globals). The marker that
// reaches each effective leaf names the source that won it.
// SELF-CHECK on every run: the same pipeline over the UNMARKED sources must reproduce Helm's real effective values;
// where it does not (a --set list index merges differently), origins are REFUSED by name, never guessed.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	chart "helm.sh/helm/v4/pkg/chart/v2"

	"helm.sh/helm/v4/pkg/chart/common"
	"helm.sh/helm/v4/pkg/chart/common/util"
	"helm.sh/helm/v4/pkg/chart/v2/loader"
	"helm.sh/helm/v4/pkg/strvals"
)

const marker = "\x00cartograph-origin\x1f"

// Layer is one values source.
type Layer struct {
	ID    string `json:"id"`
	Kind  string `json:"kind"` // chart | subchart | file | set
	File  string `json:"file,omitempty"`
	Set   string `json:"set,omitempty"`
	Scope string `json:"scope,omitempty"` // where its keys land in the effective values ("" = the root; "sub" for a subchart)
}

// Def is a leaf a layer sets (Nil: it sets null — a removal when a default exists).
type Def struct {
	Path string `json:"path"`
	Nil  bool   `json:"nil,omitempty"`
}

// Origins is the answer: every effective leaf's value and the source that won it.
type Origins struct {
	Layers  []Layer           `json:"layers"`
	Values  map[string]string `json:"values"`
	Origin  map[string]string `json:"origin"`  // effective path -> "<layer id>\x1f<path inside that source>"
	Defined map[string][]Def  `json:"defined"` // layer id -> the leaves it sets
	Refused string            `json:"refused,omitempty"`
}

func taint(m map[string]any, id, prefix string) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		p := k
		if prefix != "" {
			p = prefix + "." + k
		}
		switch x := v.(type) {
		case map[string]any:
			out[k] = taint(x, id, p)
		case nil:
			out[k] = nil
		default:
			out[k] = marker + id + "\x1f" + p
		}
	}
	return out
}

func leaves(m map[string]any, prefix string, f func(path string, v any)) {
	for k, v := range m {
		p := k
		if prefix != "" {
			p = prefix + "." + k
		}
		if x, ok := v.(map[string]any); ok && len(x) > 0 {
			leaves(x, p, f)
		} else {
			f(p, v)
		}
	}
}

func canon(v any) string {
	switch x := v.(type) {
	case nil:
		return "null"
	case bool:
		return fmt.Sprintf("bool:%v", x)
	case string:
		return "str:" + x
	case float64:
		return fmt.Sprintf("number:%.17g", x)
	case float32:
		return fmt.Sprintf("number:%.17g", float64(x))
	case int:
		return fmt.Sprintf("number:%.17g", float64(x))
	case int64:
		return fmt.Sprintf("number:%.17g", float64(x))
	case map[string]any:
		if len(x) == 0 {
			return "map:{}"
		}
	}
	b, err := json.Marshal(v)
	if err != nil {
		return fmt.Sprintf("other:%v", v)
	}
	return "json:" + string(b)
}

// the user values the way Helm builds them (cli/values Options.MergeValues): -f files merged in order, then --set
func userValues(files, sets []string, mark bool, layers *[]Layer) (map[string]any, error) {
	base := map[string]any{}
	for i, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		m, err := loader.LoadValues(strings.NewReader(string(raw)))
		if err != nil {
			return nil, fmt.Errorf("failed to parse %s: %w", f, err)
		}
		if mark {
			id := fmt.Sprintf("f%d", i+1)
			*layers = append(*layers, Layer{ID: id, Kind: "file", File: f})
			m = taint(m, id, "")
		}
		base = loader.MergeMaps(base, m)
	}
	for i, s := range sets {
		m := map[string]any{}
		if err := strvals.ParseInto(s, m); err != nil {
			return nil, fmt.Errorf("failed parsing --set data: %w", err)
		}
		if mark {
			id := fmt.Sprintf("s%d", i+1)
			*layers = append(*layers, Layer{ID: id, Kind: "set", Set: s})
			m = taint(m, id, "")
		}
		base = loader.MergeMaps(base, m)
	}
	return base, nil
}

// mark a chart's own defaults and its subcharts', recording each as a layer (scope = where its keys land)
func markChart(ch *chart.Chart, dir, scope string, layers *[]Layer) {
	id := "chart"
	kind := "chart"
	if scope != "" {
		id, kind = "chart:"+scope, "subchart"
	}
	file := filepath.Join(dir, "values.yaml")
	*layers = append(*layers, Layer{ID: id, Kind: kind, File: file, Scope: scope})
	ch.Values = taint(ch.Values, id, "")
	for _, sub := range ch.Dependencies() {
		s := sub.Name()
		if scope != "" {
			s = scope + "." + s
		}
		markChart(sub, filepath.Join(dir, "charts", sub.Name()), s, layers)
	}
}

func defined(m map[string]any) []Def {
	var out []Def
	leaves(m, "", func(p string, v any) { out = append(out, Def{Path: p, Nil: v == nil}) })
	sort.Slice(out, func(i, j int) bool { return out[i].Path < out[j].Path })
	return out
}

func chartDefined(ch *chart.Chart, scope string, into map[string][]Def) {
	id := "chart"
	if scope != "" {
		id = "chart:" + scope
	}
	into[id] = defined(ch.Values)
	for _, sub := range ch.Dependencies() {
		s := sub.Name()
		if scope != "" {
			s = scope + "." + s
		}
		chartDefined(sub, s, into)
	}
}

// computeOrigins runs the marked pipeline and the self-check against Helm's real effective values (real)
func computeOrigins(chartDir string, files, sets []string, opts common.ReleaseOptions, real map[string]any) *Origins {
	o := &Origins{Values: map[string]string{}, Origin: map[string]string{}, Defined: map[string][]Def{}}
	refuse := func(why string) *Origins { o.Refused = why; return o }
	// (the sources as they are, for `defined`)
	plain, err := loader.Load(chartDir)
	if err != nil {
		return refuse("load: " + err.Error())
	}
	chartDefined(plain, "", o.Defined)
	for i, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			return refuse(err.Error())
		}
		m, err := loader.LoadValues(strings.NewReader(string(raw)))
		if err != nil {
			return refuse(err.Error())
		}
		o.Defined[fmt.Sprintf("f%d", i+1)] = defined(m)
	}
	for i, s := range sets {
		m := map[string]any{}
		if err := strvals.ParseInto(s, m); err != nil {
			return refuse(err.Error())
		}
		o.Defined[fmt.Sprintf("s%d", i+1)] = defined(m)
	}
	// SELF-CHECK: the replicated pipeline, unmarked, against Helm's own
	uv, err := userValues(files, sets, false, nil)
	if err != nil {
		return refuse(err.Error())
	}
	// (the schema was judged on the real values; the marked copies hold strings where it wants types)
	rv, err := util.ToRenderValuesWithSchemaValidation(plain, uv, opts, common.DefaultCapabilities, true)
	if err != nil {
		return refuse("render values: " + err.Error())
	}
	repl := map[string]string{}
	leaves(asMap(rv["Values"]), "", func(p string, v any) { repl[p] = canon(v) })
	leaves(real, "", func(p string, v any) { o.Values[p] = canon(v) })
	for p, v := range o.Values {
		if repl[p] != v {
			return refuse(fmt.Sprintf("the replicated merge differs from Helm's at %s (%s vs %s)", p, repl[p], v))
		}
	}
	for p := range repl {
		if _, ok := o.Values[p]; !ok {
			return refuse("the replicated merge has a value Helm's does not: " + p)
		}
	}
	// the MARKED pipeline
	marked, err := loader.Load(chartDir)
	if err != nil {
		return refuse("load: " + err.Error())
	}
	markChart(marked, chartDir, "", &o.Layers)
	mv, err := userValues(files, sets, true, &o.Layers)
	if err != nil {
		return refuse(err.Error())
	}
	rvm, err := util.ToRenderValuesWithSchemaValidation(marked, mv, opts, common.DefaultCapabilities, true)
	if err != nil {
		return refuse("marked render values: " + err.Error())
	}
	leaves(asMap(rvm["Values"]), "", func(p string, v any) {
		if s, ok := v.(string); ok && strings.HasPrefix(s, marker) {
			o.Origin[p] = strings.TrimPrefix(s, marker)
		}
	})
	return o
}

// asMap reads an effective values table whichever map type carries it
func asMap(v any) map[string]any {
	switch x := v.(type) {
	case common.Values:
		return x.AsMap()
	case map[string]any:
		return x
	}
	return map[string]any{}
}
