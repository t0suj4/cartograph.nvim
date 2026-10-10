// gooracle: the TYPE CHECKER's answer for every selector call `x.m(...)` in a Go module's packages — the oracle
// cartograph.flowtype's Go walker is scored against (CART-1621). Usage: gooracle <module root> <pkg dir>...
// Prints TSV: file  line  col  method  kind  recvtype  declfile  declline   (line/col 0-based of the selector's x)
package main

import (
	"fmt"
	"go/ast"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func main() {
	root := os.Args[1]
	fset := token.NewFileSet()
	// export data: `go list -export -deps` writes "importpath exportfile" lines to os.Args[2]
	exports := map[string]string{}
	if b, err := os.ReadFile(os.Args[2]); err == nil {
		for _, ln := range strings.Split(string(b), "\n") {
			f := strings.SplitN(ln, " ", 2)
			if len(f) == 2 && f[1] != "" {
				exports[f[0]] = f[1]
			}
		}
	}
	imp := importer.ForCompiler(fset, "gc", func(path string) (io.ReadCloser, error) {
		if e, ok := exports[path]; ok {
			return os.Open(e)
		}
		return nil, fmt.Errorf("no export data for %s", path)
	})
	type row struct {
		sel  *ast.SelectorExpr
		s    *types.Selection
	}
	var named []*types.Named
	var rows []row
	for _, dir := range os.Args[3:] {
		pkgs, err := parser.ParseDir(fset, dir, func(fi os.FileInfo) bool { return !strings.HasSuffix(fi.Name(), "_test.go") }, 0)
		if err != nil {
			fmt.Fprintln(os.Stderr, "parse", dir, err)
			continue
		}
		for _, p := range pkgs {
			var files []*ast.File
			names := []string{}
			for n := range p.Files {
				names = append(names, n)
			}
			sort.Strings(names)
			for _, n := range names {
				files = append(files, p.Files[n])
			}
			info := &types.Info{Selections: map[*ast.SelectorExpr]*types.Selection{}, Types: map[ast.Expr]types.TypeAndValue{}, Defs: map[*ast.Ident]types.Object{}}
			conf := types.Config{Importer: imp, Error: func(err error) {}}
			_, _ = conf.Check(p.Name, fset, files, info)
			for _, obj := range info.Defs {
				if tn, ok := obj.(*types.TypeName); ok {
					if nt, ok := tn.Type().(*types.Named); ok && !types.IsInterface(nt) {
						named = append(named, nt)
					}
				}
			}
			for _, f := range files {
				ast.Inspect(f, func(n ast.Node) bool {
					call, ok := n.(*ast.CallExpr)
					if !ok {
						return true
					}
					sel, ok := call.Fun.(*ast.SelectorExpr)
					if !ok {
						return true
					}
					s := info.Selections[sel]
					if s == nil || s.Kind() != types.MethodVal {
						return true
					}
					rows = append(rows, row{sel, s})
					return true
				})
			}
		}
	}
	rel := func(p string) string {
		r, err := filepath.Rel(root, p)
		if err != nil || strings.HasPrefix(r, "..") {
			return "EXTERNAL:" + p
		}
		return r
	}
	for _, r := range rows {
		fn, _ := r.s.Obj().(*types.Func)
		if fn == nil {
			continue
		}
		pos := fset.Position(r.sel.X.Pos())
		rt := r.s.Recv()
		kind := "concrete"
		impl := ""
		if types.IsInterface(rt) {
			kind = "interface"
			iface, _ := rt.Underlying().(*types.Interface)
			var ims []string
			for _, nt := range named {
				// (BY METHOD NAMES: each package is checked in its own universe — an imported interface and a
				// source-checked type are different objects to types.Implements)
				t := types.NewPointer(nt)
				ms := types.NewMethodSet(t)
				all := iface != nil
				for i := 0; all && i < iface.NumMethods(); i++ {
					if ms.Lookup(nil, iface.Method(i).Name()) == nil {
						found := false
						for j := 0; j < ms.Len(); j++ {
							if ms.At(j).Obj().Name() == iface.Method(i).Name() {
								found = true
							}
						}
						all = found
					}
				}
				if all {
					for j := 0; j < ms.Len(); j++ {
						if m, ok := ms.At(j).Obj().(*types.Func); ok && m.Name() == fn.Name() {
							mp := fset.Position(m.Pos())
							ims = append(ims, fmt.Sprintf("%s:%d", rel(mp.Filename), mp.Line-1))
						}
					}
				}
			}
			sort.Strings(ims)
			impl = strings.Join(ims, ",")
		}
		dp := fset.Position(fn.Pos())
		fmt.Printf("%s\t%d\t%d\t%s\t%s\t%s\t%s\t%d\t%s\n", rel(pos.Filename), pos.Line-1, pos.Column-1, r.sel.Sel.Name, kind, rt.String(), rel(dp.Filename), dp.Line-1, impl)
	}
}