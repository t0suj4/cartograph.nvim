// PROVENANCE (cartograph CART-0870): Go's text/template already knows, at every step, which parse node it is executing
// (state.at, for its error messages) and where that node sits in its template (Tree.ErrorContext). This copy keeps that
// attribution instead of throwing it away: every output byte range a top-level execution writes, to the action or
// text node that wrote it, and every `.Values` chain evaluated, to the node that evaluated it (inside `include`d helpers
// too). Recording is OFF unless Rec is set: with Rec nil the executor is the standard library's.
package template

import (
	"io"
	"strings"

	"cartograph/helmprov/tpl/parse"
)

// Span is one node's output: [Start, End) bytes of its file's rendered text.
type Span struct {
	Start  int      `json:"start"`
	End    int      `json:"end"`
	Loc    string   `json:"loc"`
	Kind   string   `json:"kind"`
	Values []string `json:"values,omitempty"`
}

// Read is one `.Values` chain evaluated at a node.
type Read struct {
	Path string `json:"path"`
	Loc  string `json:"loc"`
}

// File is one rendered template's provenance.
type File struct {
	Spans []*Span `json:"spans"`
}

// Recorder collects provenance across one render.
type Recorder struct {
	Files map[string]*File `json:"files"`
	Reads []Read           `json:"reads"`
	depth int
}

// Rec is the active recorder (nil: no recording).
var Rec *Recorder

// NewRecorder starts recording.
func NewRecorder() *Recorder { return &Recorder{Files: map[string]*File{}} }

type countWriter struct {
	w io.Writer
	n int
}

func (c *countWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += n
	return n, err
}

func loc(n parse.Node, t *Template) string {
	if n == nil || t == nil || t.Tree == nil {
		return ""
	}
	l, _ := t.ErrorContext(n)
	return l
}

func (s *state) recordRead(n parse.Node, path []string) {
	if Rec == nil || len(path) == 0 {
		return
	}
	p := strings.Join(path, ".")
	Rec.Reads = append(Rec.Reads, Read{Path: p, Loc: loc(n, s.tmpl)})
	if s.cur != nil {
		s.cur.Values = append(s.cur.Values, p)
	}
}

// Finish maps a file's spans through the engine's removal of "<no value>" (each occurrence deletes its bytes from the
// output after execution) and returns the text as the engine emits it.
func (r *Recorder) Finish(name, raw string) string {
	const nv = "<no value>"
	f := r.Files[name]
	if f == nil || !strings.Contains(raw, nv) {
		return strings.ReplaceAll(raw, nv, "")
	}
	var cuts []int
	for i := 0; ; {
		j := strings.Index(raw[i:], nv)
		if j < 0 {
			break
		}
		cuts = append(cuts, i+j)
		i += j + len(nv)
	}
	shift := func(x int) int {
		d := 0
		for _, c := range cuts {
			if c+len(nv) <= x {
				d += len(nv)
			} else if c < x {
				d += x - c
			}
		}
		return x - d
	}
	for _, sp := range f.Spans {
		sp.Start, sp.End = shift(sp.Start), shift(sp.End)
	}
	return strings.ReplaceAll(raw, nv, "")
}
