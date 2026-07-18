// TS-analyzer ground truth for the disagreement harvest (tools/harvest_ts.lua).
// The TypeScript compiler API's type checker resolves every CallExpression's
// callee to its declaration(s) — the same engine tsserver uses, run as a batch
// (no LSP round-trips). Emits JSON keyed like cartograph:
//   { calls: [ {file, line(0-based), callee, defs:[{file,name,line}]} ] }
// A def in a .d.ts is treated as out-of-corpus (external), like cartograph.
//
// PREREQUISITE (external, not a repo dep — like the patched lua-ls the lua
// harvest needs): `npm i typescript` somewhere on NODE_PATH, or run from a dir
// with typescript installed. USAGE:
//   node tools/tsresolve.mjs <corpus-root> [subpath-filter] > dump.json
//   nvim -l tools/harvest_ts.lua <corpus-root> dump.json
import ts from 'typescript';
import * as path from 'path';
import * as fs from 'fs';

const root = process.argv[2];
const limitDir = process.argv[3]; // optional sub-path filter for speed
function walk(dir, out) {
  for (const e of fs.readdirSync(dir, {withFileTypes:true})) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { if (e.name!=='node_modules'&&e.name!=='.git') walk(p,out); }
    else if (/\.(ts|tsx)$/.test(e.name) && !e.name.endsWith('.d.ts')) out.push(p);
  }
}
const files = []; walk(root, files);
const rootFiles = limitDir ? files.filter(f=>f.includes(limitDir)) : files;
// program over ALL files (cross-file resolution) but we only emit for rootFiles
const program = ts.createProgram(files, {
  allowJs:true, jsx: ts.JsxEmit.Preserve, target: ts.ScriptTarget.ES2020,
  module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler,
  noResolve:false, skipLibCheck:true, noLib:true, allowNonTsExtensions:true,
});
const checker = program.getTypeChecker();
const rel = f => path.relative(root, f);
const calls = [];
let nCalls=0, nResolved=0;
for (const sf of program.getSourceFiles()) {
  if (sf.isDeclarationFile) continue;
  if (!rootFiles.includes(sf.fileName)) continue;
  const visit = (node) => {
    if (ts.isCallExpression(node)) {
      let nameNode=null, callee=null;
      const e = node.expression;
      if (ts.isIdentifier(e)) { nameNode=e; callee=e.text; }
      else if (ts.isPropertyAccessExpression(e)) { nameNode=e.name; callee=e.name.text; }
      if (nameNode && callee) {
        nCalls++;
        const {line} = sf.getLineAndCharacterOfPosition(node.getStart());
        let sym = checker.getSymbolAtLocation(nameNode);
        if (sym && sym.flags & ts.SymbolFlags.Alias) { try { sym = checker.getAliasedSymbol(sym); } catch {} }
        const defs=[];
        for (const d of (sym?.declarations||[])) {
          const dsf = d.getSourceFile();
          if (dsf.isDeclarationFile) continue; // external .d.ts = out of corpus
          const dl = dsf.getLineAndCharacterOfPosition(d.getStart()).line;
          const nm = (d.name?.text) || (d.symbol?.name) || callee;
          defs.push({file: rel(dsf.fileName), name: nm, line: dl});
        }
        if (defs.length) nResolved++;
        calls.push({file: rel(sf.fileName), line, callee, defs});
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(sf);
}
process.stderr.write(`files=${rootFiles.length} calls=${nCalls} resolved-in-corpus=${nResolved}\n`);
process.stdout.write(JSON.stringify({calls}));
