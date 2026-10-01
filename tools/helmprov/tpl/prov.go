// PROVENANCE (cartograph CART-0870): Go's text/template already knows, at every step, which parse node it is executing
// (state.at, for its error messages) and where that node sits in its template (Tree.ErrorContext). This copy keeps that
// attribution instead of throwing it away: every output byte range a top-level execution writes, to the action or
// text node that wrote it, and every `.Values` chain evaluated, to the node that evaluated it (inside `include`d helpers
// too). Recording is OFF unless Rec is set: with Rec nil the executor is the standard library's.
//
// ALL BRANCHES (CART-0871): with Rec.Branches set, every arm the values did NOT take is executed too — into its own
// buffer, never the file, with the variables restored after — so its `.Values` reads are recorded, tagged untaken with
// the GUARD that skipped them, and its text is kept beside the guard; an untaken arm that fails
// (`{{ if .Values.a }}{{ .Values.a.b }}` with no a) is a HOLE (its text up to the failure, the error), not an error. Run it as
// a SEPARATE render: an untaken arm may call a mutating function (sprig's set / merge), so the authoritative render is
// the one without exploration.
package template

import (
	"fmt"
	"io"
	"reflect"
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

// Read is one `.Values` chain evaluated at a node; Untaken when it sits in an arm the values skipped (Guard names the
// innermost such arm: `<loc> <if|with|range> <pipeline> (<then|else|body>)`).
type Read struct {
	Path    string `json:"path"`
	Loc     string `json:"loc"`
	Untaken bool   `json:"untaken,omitempty"`
	Guard   string `json:"guard,omitempty"`
}

// Arm is one execution of a control node: which arm the values took.
type Arm struct {
	Loc     string `json:"loc"`
	Kind    string `json:"kind"`
	Pipe    string `json:"pipe"`
	Taken   string `json:"taken"` // then | else | none (an if/with with no else, false) | body | empty
	Else    bool   `json:"else,omitempty"` // the node has an else arm
	Untaken bool   `json:"untaken,omitempty"`
}

// Explored is one execution of an untaken arm: its rendered text; a HOLE when it failed (Err, at Loc).
type Explored struct {
	Guard string `json:"guard"`
	Text  string `json:"text"`
	Loc   string `json:"loc,omitempty"`
	Err   string `json:"err,omitempty"`
}

// File is one rendered template's provenance.
type File struct {
	Spans []*Span `json:"spans"`
}

// Recorder collects provenance across one render.
type Recorder struct {
	Files    map[string]*File `json:"files"`
	Reads    []Read           `json:"reads"`
	Arms     []Arm            `json:"arms,omitempty"`
	Explored []Explored       `json:"explored,omitempty"`
	Branches bool             `json:"-"`
	depth    int
	guards   []string // the untaken arms being explored, innermost last
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
	r := Read{Path: p, Loc: loc(n, s.tmpl)}
	if g := len(Rec.guards); g > 0 {
		r.Untaken, r.Guard = true, Rec.guards[g-1]
	}
	Rec.Reads = append(Rec.Reads, r)
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

// arm records which arm of a control node the values took (exploring only).
func (s *state) arm(n parse.Node, kind string, pipe *parse.PipeNode, taken string, hasElse bool) {
	if Rec == nil || !Rec.Branches {
		return
	}
	Rec.Arms = append(Rec.Arms, Arm{Loc: loc(n, s.tmpl), Kind: kind, Pipe: pipe.String(), Taken: taken, Else: hasElse, Untaken: len(Rec.guards) > 0})
}

// maxGuards bounds nested exploration (each level is one untaken arm inside another).
const maxGuards = 16

// explore executes an arm the values did not take: output discarded, variables restored, a failure recorded as a hole.
// pre (optional) binds what the arm expects (a range body's variables). A guard already being explored is not
// re-entered (a recursive template's untaken self-call).
func (s *state) explore(n parse.Node, kind string, pipe *parse.PipeNode, which string, dot reflect.Value, list *parse.ListNode, pre func()) {
	if Rec == nil || !Rec.Branches || list == nil || len(Rec.guards) >= maxGuards {
		return
	}
	guard := fmt.Sprintf("%s %s %s (%s)", loc(n, s.tmpl), kind, pipe.String(), which)
	for _, g := range Rec.guards {
		if g == guard {
			return
		}
	}
	saved := make([]variable, len(s.vars))
	copy(saved, s.vars)
	wr, cw, cur, node := s.wr, s.cw, s.cur, s.node
	var buf strings.Builder
	s.wr, s.cw, s.cur = &buf, nil, nil
	Rec.guards = append(Rec.guards, guard)
	defer func() {
		x := Explored{Guard: guard}
		if r := recover(); r != nil && r != walkBreak && r != walkContinue {
			x.Err = fmt.Sprint(r)
			if e, ok := r.(ExecError); ok {
				x.Err = e.Err.Error()
			}
			x.Loc = loc(s.node, s.tmpl)
		}
		x.Text = strings.ReplaceAll(buf.String(), "<no value>", "")
		Rec.Explored = append(Rec.Explored, x)
		Rec.guards = Rec.guards[:len(Rec.guards)-1]
		s.vars = saved
		s.wr, s.cw, s.cur, s.node = wr, cw, cur, node
	}()
	if pre != nil {
		pre()
	}
	s.walk(dot, list)
}
