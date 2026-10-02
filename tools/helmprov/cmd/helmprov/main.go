// helmprov — render a chart through HELM'S OWN ENGINE with the provenance-recording copy of text/template (cartograph
// CART-0870) and print one JSON document: every rendered file's text, the spans that attribute each output byte range
// to the template node (file:line:col) that wrote it, and every .Values chain evaluated with its node. -branches
// (CART-0871) adds the arms the values did NOT take: a second render executes them (output discarded) and contributes
// only what the first cannot see — their reads (untaken, with the guard), every control node's taken arm, and each
// untaken arm's rendered text (a hole when it fails: its error and node). The files and spans are always the first, unexplored render's.
//
// -origins (CART-1307) adds, for every effective value, the values source that won it (origin.go).
//
//	helmprov [-release NAME] [-namespace NS] [-f values.yaml]... [-set k=v]... [-branches] [-origins] <chart dir>
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"cartograph/helmprov/engine"
	template "cartograph/helmprov/tpl"

	"helm.sh/helm/v4/pkg/chart/common"
	"helm.sh/helm/v4/pkg/chart/common/util"
	"helm.sh/helm/v4/pkg/chart/v2/loader"
	"helm.sh/helm/v4/pkg/cli/values"
	"helm.sh/helm/v4/pkg/getter"
)

type multi []string

func (m *multi) String() string     { return fmt.Sprint(*m) }
func (m *multi) Set(v string) error { *m = append(*m, v); return nil }

type fileOut struct {
	Content string           `json:"content"`
	Spans   []*template.Span `json:"spans"`
}

func main() {
	release := flag.String("release", "release", "release name")
	ns := flag.String("namespace", "default", "namespace")
	branches := flag.Bool("branches", false, "also execute the untaken arms (reads, arms, holes)")
	symbolic := flag.Bool("symbolic", false, "render with NO values: .Values a placeholder, every arm explored (CART-1302)")
	origins := flag.Bool("origins", false, "for every effective value, the values source that won it (CART-1307)")
	var files, sets multi
	flag.Var(&files, "f", "values file (repeatable)")
	flag.Var(&sets, "set", "k=v override (repeatable)")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: helmprov [-release N] [-namespace NS] [-f values.yaml]... [-set k=v]... [-branches] <chart dir>")
		os.Exit(2)
	}
	fail := func(what string, err error) { fmt.Fprintf(os.Stderr, "helmprov: %s: %v\n", what, err); os.Exit(1) }
	ch, err := loader.Load(flag.Arg(0))
	if err != nil {
		fail("load", err)
	}
	vals, err := (&values.Options{ValueFiles: files, Values: sets}).MergeValues(getter.Providers{})
	if err != nil {
		fail("values", err)
	}
	opts := common.ReleaseOptions{Name: *release, Namespace: *ns, Revision: 1, IsInstall: true}
	// a symbolic render reads no values, so the values schema has nothing to judge
	rv, err := util.ToRenderValuesWithSchemaValidation(ch, vals, opts, common.DefaultCapabilities, *symbolic)
	if err != nil {
		fail("render values", err)
	}
	var org *Origins
	if *origins && !*symbolic {
		// (before the render: the engine is handed rv afterwards, and a template may mutate a values map)
		org = computeOrigins(flag.Arg(0), files, sets, opts, asMap(rv["Values"]))
	}
	template.Rec = template.NewRecorder()
	if *symbolic {
		// ONE render, with nothing concrete to be authoritative about: its files ARE the symbolic text
		template.Rec.Symbolic, template.Rec.Branches = true, true
	}
	out, err := engine.Render(ch, rv)
	if err != nil {
		fail("render", err)
	}
	res := struct {
		Files    map[string]fileOut  `json:"files"`
		Reads    []template.Read     `json:"reads"`
		Arms     []template.Arm      `json:"arms,omitempty"`
		Explored []template.Explored `json:"explored,omitempty"`
		Origins  *Origins            `json:"origins,omitempty"`
	}{Files: map[string]fileOut{}, Reads: template.Rec.Reads, Origins: org}
	first := template.Rec
	if *symbolic {
		res.Reads, res.Arms, res.Explored = first.Reads, first.Arms, first.Explored
		if res.Arms == nil {
			res.Arms = []template.Arm{}
		}
	} else if *branches {
		// the explored render: from it only what lies in untaken arms, plus the arms and holes
		rv2, err := util.ToRenderValues(ch, vals, opts, common.DefaultCapabilities)
		if err != nil {
			fail("render values", err)
		}
		template.Rec = template.NewRecorder()
		template.Rec.Branches = true
		if _, err := engine.Render(ch, rv2); err != nil {
			fail("explored render", err)
		}
		for _, r := range template.Rec.Reads {
			if r.Untaken {
				res.Reads = append(res.Reads, r)
			}
		}
		res.Arms, res.Explored = template.Rec.Arms, template.Rec.Explored
		if res.Arms == nil {
			res.Arms = []template.Arm{}
		}
	}
	for name, text := range out {
		f := first.Files[name]
		var spans []*template.Span
		if f != nil {
			spans = f.Spans
		}
		res.Files[name] = fileOut{Content: text, Spans: spans}
	}
	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(res); err != nil {
		fail("encode", err)
	}
}
