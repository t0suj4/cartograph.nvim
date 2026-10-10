// tsoracle — the TypeScript CHECKER's answer for every method call `x.m(...)` in a project: the oracle
// cartograph.flowtype's JS/TS walker is scored against (CART-1621).
//   node oracle.js <path to the typescript package> <project root> [tsconfig]
// TSV: file  line  col  method  kind  declfile  declline   (line/col 0-based, of the call's receiver expression;
//   kind = class | object | interface | other — what holds the resolved declaration)
const path = require('path');
const ts = require(process.argv[2]);
const root = path.resolve(process.argv[3]);
const cfgPath = process.argv[4] ? path.resolve(process.argv[4]) : ts.findConfigFile(root, ts.sys.fileExists);
let options = { allowJs: true, noEmit: true, skipLibCheck: true }, files = [];
if (cfgPath) {
  const cfg = ts.getParsedCommandLineOfConfigFile(cfgPath, {}, { ...ts.sys, onUnRecoverableConfigFileDiagnostic: () => {} });
  if (cfg) { options = { ...cfg.options, noEmit: true }; files = cfg.fileNames; }
}
if (files.length === 0) files = ts.sys.readDirectory(root, ['.ts', '.tsx'], ['node_modules'], undefined);
const program = ts.createProgram(files, options);
const checker = program.getTypeChecker();
const rel = (f) => { const r = path.relative(root, f); return r.startsWith('..') || r.includes('node_modules') ? 'EXTERNAL:' + f : r; };
for (const sf of program.getSourceFiles()) {
  if (sf.isDeclarationFile) continue;
  const file = rel(sf.fileName);
  if (file.startsWith('EXTERNAL:')) continue;
  const visit = (n) => {
    if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression)) {
      const pa = n.expression;
      let sym = checker.getSymbolAtLocation(pa.name);
      if (sym && (sym.flags & ts.SymbolFlags.Alias)) sym = checker.getAliasedSymbol(sym);
      const decl = sym && sym.declarations && sym.declarations[0];
      if (decl) {
        const p = decl.parent;
        // (the checker's answer is a DECLARATION: a method with a body IS the callee; an abstract method, or a field /
        // property holding a function value, is only the slot — flow names the value in it: scored for coverage only)
        let kind = 'other';
        const fnInit = (d) => d.initializer && (ts.isFunctionExpression(d.initializer) || ts.isArrowFunction(d.initializer));
        if (p && (ts.isClassDeclaration(p) || ts.isClassExpression(p))) {
          if (ts.isMethodDeclaration(decl)) kind = decl.body ? 'class' : 'abstract';
          else kind = (ts.isPropertyDeclaration(decl) && fnInit(decl)) ? 'class' : 'field';
        } else if (p && ts.isObjectLiteralExpression(p)) {
          kind = (ts.isMethodDeclaration(decl) || (ts.isPropertyAssignment(decl) && fnInit(decl))) ? 'object' : 'field';
        } else if (p && (ts.isInterfaceDeclaration(p) || ts.isTypeLiteralNode(p))) kind = 'interface';
        else if (ts.isFunctionDeclaration(decl)) kind = 'function';
        const at = sf.getLineAndCharacterOfPosition(pa.expression.getStart(sf));
        const dsf = decl.getSourceFile();
        const dat = dsf.getLineAndCharacterOfPosition(decl.getStart(dsf));
        process.stdout.write([file, at.line, at.character, pa.name.text, kind, rel(dsf.fileName), dat.line].join('\t') + '\n');
      }
    }
    ts.forEachChild(n, visit);
  };
  visit(sf);
}
