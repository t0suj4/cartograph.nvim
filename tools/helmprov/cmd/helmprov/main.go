// helmprov — render a chart through HELM'S OWN ENGINE with the provenance-recording copy of text/template (cartograph
// CART-0870) and print one JSON document: every rendered file's text, the spans that attribute each output byte range
// to the template node (file:line:col) that wrote it, and every .Values chain evaluated with its node.
//
//	helmprov [-release NAME] [-namespace NS] [-f values.yaml]... [-set k=v]... <chart dir>
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
	var files, sets multi
	flag.Var(&files, "f", "values file (repeatable)")
	flag.Var(&sets, "set", "k=v override (repeatable)")
	flag.Parse()
	if flag.NArg() != 1 {
		fmt.Fprintln(os.Stderr, "usage: helmprov [-release N] [-namespace NS] [-f values.yaml]... [-set k=v]... <chart dir>")
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
	rv, err := util.ToRenderValues(ch, vals, opts, common.DefaultCapabilities)
	if err != nil {
		fail("render values", err)
	}
	template.Rec = template.NewRecorder()
	out, err := engine.Render(ch, rv)
	if err != nil {
		fail("render", err)
	}
	res := struct {
		Files map[string]fileOut `json:"files"`
		Reads []template.Read    `json:"reads"`
	}{Files: map[string]fileOut{}, Reads: template.Rec.Reads}
	for name, text := range out {
		f := template.Rec.Files[name]
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
