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
//
// SYMBOLIC (CART-1302): with Rec.Symbolic set the engine hands every template a Sym for `.Values` — no values needed. A
// field of a Sym is a Sym one segment longer (`.Values.a.b`), and its read is recorded at its FINAL path, dot-relative
// ones inside with/range included. Its truth is UNKNOWN: the then-arm renders and the else-arm is explored. Ranging
// over it is one symbolic element (`a[]`). Printed, it is a hole marker `⟨.Values.a.b⟩`, and toYaml/toJson see the same
// string. A function that cannot take a Sym — a typed parameter, or a builtin — is NOT called: its result is a Sym
// named by its expression. An action that fails is a hole, not the end of the render.
package template

import (
	"encoding/json"
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
	Taken   string `json:"taken"`           // then | else | none (an if/with with no else, false) | body | empty | unknown (symbolic)
	Else    bool   `json:"else,omitempty"`  // the node has an else arm
	Value   string `json:"value,omitempty"` // what the condition / range pipeline evaluated to (CART-1309)
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
	Symbolic bool             `json:"-"`
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
func (s *state) arm(n parse.Node, kind string, pipe *parse.PipeNode, taken string, hasElse bool, value string) {
	if Rec == nil || !Rec.Branches {
		return
	}
	Rec.Arms = append(Rec.Arms, Arm{Loc: loc(n, s.tmpl), Kind: kind, Pipe: pipe.String(), Taken: taken, Else: hasElse, Value: value, Untaken: len(Rec.guards) > 0})
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

// Sym is a value the render does not know: a `.Values` path, or an expression over unknowns.
type Sym struct {
	Path string // the .Values path ("" = .Values itself) when Expr is empty
	Expr string // a derived expression (a call, a key) — not a values path
}

// inner is the expression a Sym stands for, unbracketed.
func (y Sym) inner() string {
	if y.Expr != "" {
		return y.Expr
	}
	if y.Path == "" {
		return ".Values"
	}
	return ".Values." + y.Path
}

func (y Sym) String() string {
	switch {
	case y.Expr != "":
		return "\u27e8" + y.Expr + "\u27e9"
	case y.Path == "":
		return "\u27e8.Values\u27e9"
	}
	return "\u27e8.Values." + y.Path + "\u27e9"
}

// MarshalJSON makes toYaml / toJson print the marker.
func (y Sym) MarshalJSON() ([]byte, error) { return json.Marshal(y.String()) }

// Field is a Sym one segment longer.
func (y Sym) Field(f string) Sym { return y.field(f) }

func (y Sym) field(f string) Sym {
	sep := "." // an element segment `[]` joins without one: `a[].b`
	if strings.HasPrefix(f, "[") {
		sep = ""
	}
	if y.Expr != "" {
		return Sym{Expr: y.Expr + sep + f}
	}
	if y.Path == "" {
		return Sym{Path: f}
	}
	return Sym{Path: y.Path + sep + f}
}

var symType = reflect.TypeFor[Sym]()

// symOf reports whether v (through interfaces and pointers) is a Sym.
func symOf(v reflect.Value) (Sym, bool) {
	for v.IsValid() && (v.Kind() == reflect.Interface || v.Kind() == reflect.Pointer) && !v.IsNil() {
		v = v.Elem()
	}
	if v.IsValid() && v.Type() == reflectValueType {
		return symOf(v.Interface().(reflect.Value))
	}
	if v.IsValid() && v.Type() == symType {
		return v.Interface().(Sym), true
	}
	return Sym{}, false
}

func symbolic() bool { return Rec != nil && Rec.Symbolic }

// recordSym records a symbolic values read at its final path.
func (s *state) recordSym(n parse.Node, v reflect.Value) {
	if y, ok := symOf(v); ok && y.Expr == "" && y.Path != "" {
		s.recordRead(n, []string{y.Path})
	}
}

// PASS-THROUGH functions given a Sym in an interface{} slot: their result means something with the marker in it.
var symPass = map[string]bool{"quote": true, "squote": true, "default": true, "toYaml": true, "toJson": true,
	"toPrettyJson": true, "mustToJson": true, "toRawJson": true, "printf": true, "print": true, "println": true,
	"required": true, "coalesce": true, "list": true, "dict": true, "include": true, "nindent": false, "indent": false}

// symCall decides a call given its evaluated args: a Sym result when any arg is a Sym the function cannot take
// (hit, from validateType) or a builtin / unknown function receives one; `index` extends a Sym's path.
func (s *state) symCall(name string, isBuiltin bool, node parse.Node, argv []reflect.Value, hit bool, final reflect.Value) (reflect.Value, bool) {
	if !symbolic() {
		return reflect.Value{}, false
	}
	if isBuiltin && name == "index" && len(argv) > 0 {
		if y, ok := symOf(argv[0]); ok {
			for _, k := range argv[1:] {
				kv := k
				if kv.Type() == reflectValueType {
					kv = kv.Interface().(reflect.Value)
				}
				kv = indirectInterface(kv)
				if kv.IsValid() && kv.Kind() == reflect.String {
					y = y.field(kv.String())
				} else {
					y = y.field("[]")
				}
			}
			s.recordSym(node, reflect.ValueOf(y))
			return reflect.ValueOf(y), true
		}
	}
	symArg := hit
	for _, a := range argv {
		if _, ok := symOf(a); ok {
			symArg = symArg || isBuiltin || !symPass[name]
		}
	}
	if !symArg {
		return reflect.Value{}, false
	}
	expr := strings.TrimSpace(node.String())
	if fy, ok := symOf(final); ok && !isMissing(final) {
		expr = fy.inner() + " | " + expr // a pipeline stage keeps what was piped into it
	}
	return reflect.ValueOf(Sym{Expr: expr}), true
}

// symGuard runs one node of a symbolic render: an execution error becomes a hole (recorded, a marker in the output),
// never the end of the render. Off unless Symbolic; exploration (an untaken arm) records its own holes.
func (s *state) symGuard(n parse.Node, f func()) {
	if !symbolic() || len(Rec.guards) > 0 {
		f()
		return
	}
	defer func() {
		if r := recover(); r != nil {
			e, ok := r.(ExecError)
			if !ok {
				panic(r)
			}
			Rec.Explored = append(Rec.Explored, Explored{Guard: "symbolic " + loc(n, s.tmpl), Loc: loc(s.node, s.tmpl), Err: e.Err.Error()})
			fmt.Fprint(s.wr, "\u27e8error\u27e9")
		}
	}()
	f()
}

// condText is what a condition or range pipeline evaluated to, as evidence (CART-1309): a scalar typed, a
// collection by its size, a placeholder as itself
func condText(v reflect.Value) string {
	if y, ok := symOf(v); ok {
		return y.String()
	}
	v = indirectInterface(v)
	if !v.IsValid() {
		return "nil"
	}
	switch v.Kind() {
	case reflect.Bool:
		return fmt.Sprintf("bool:%v", v.Bool())
	case reflect.String:
		t := v.String()
		if len(t) > 60 {
			t = t[:60] + "…"
		}
		return "str:" + t
	case reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64:
		return fmt.Sprintf("number:%d", v.Int())
	case reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64:
		return fmt.Sprintf("number:%d", v.Uint())
	case reflect.Float32, reflect.Float64:
		return fmt.Sprintf("number:%g", v.Float())
	case reflect.Map:
		return fmt.Sprintf("map(%d)", v.Len())
	case reflect.Slice, reflect.Array:
		return fmt.Sprintf("list(%d)", v.Len())
	}
	return v.Kind().String()
}
