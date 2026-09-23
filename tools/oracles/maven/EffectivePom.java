// ORACLE for cartograph.pom (CART-1051): MAVEN'S OWN MODEL BUILDER, driven OFFLINE.
//
// The system Maven ships maven-model-builder; this drives it directly — NOT `mvn help:effective-pom`,
// which goes through the PROJECT builder and loads build extensions (139 POMs in our corpora
// declare some: that would run tree-selected code). The model builder runs nothing from the tree.
// Parents and imported BOMs resolve ONLY among the POMs given on stdin, by coordinates (what the
// reactor's model pool does); anything else is refused, never fetched — so a POM whose lineage
// leaves the tree comes back as an error, and that is the honest answer offline.
//
// stdin : NUL-separated pom.xml paths.  argv: <outdir> [profile,ids]
// stdout: NUL-separated records  OK <path> <file>  |  PARTIAL <path> <file>  |  ERR <path> <message>
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import org.apache.maven.model.*;
import org.apache.maven.model.building.*;
import org.apache.maven.model.io.xpp3.MavenXpp3Reader;
import org.apache.maven.model.io.xpp3.MavenXpp3Writer;
import org.apache.maven.model.resolution.*;

public class EffectivePom {
    static final Map<String, File> POOL = new HashMap<>();
    static final String OFFLINE = "not in the tree (offline oracle)";
    static final java.util.regex.Pattern IMPORT = java.util.regex.Pattern.compile("import POM ([^:\\s]+):([^:\\s]+):");

    static class TreeOnly implements ModelResolver {
        ModelSource find(String g, String a, String v) throws UnresolvableModelException {
            File f = POOL.get(g + ":" + a + ":" + v);
            if (f == null) throw new UnresolvableModelException(OFFLINE, g, a, v);
            return new FileModelSource(f);
        }
        public ModelSource resolveModel(String g, String a, String v) throws UnresolvableModelException { return find(g, a, v); }
        public ModelSource resolveModel(Parent p) throws UnresolvableModelException { return find(p.getGroupId(), p.getArtifactId(), p.getVersion()); }
        public ModelSource resolveModel(Dependency d) throws UnresolvableModelException { return find(d.getGroupId(), d.getArtifactId(), d.getVersion()); }
        public void addRepository(Repository r) {}
        public void addRepository(Repository r, boolean replace) {}
        public ModelResolver newCopy() { return this; }
    }

    static final Map<File, Boolean> FULL = new HashMap<>();
    static boolean buildsInFull(ModelBuilder builder, Properties sys, List<String> profiles, File f) {
        Boolean hit = FULL.get(f);
        if (hit != null) return hit;
        FULL.put(f, Boolean.FALSE); // a cycle counts as not buildable
        boolean ok;
        try { builder.build(request(f, sys, profiles)); ok = true; } catch (Exception e) { ok = false; }
        FULL.put(f, ok);
        return ok;
    }

    static DefaultModelBuildingRequest request(File pom, Properties sys, List<String> profiles) {
        DefaultModelBuildingRequest req = new DefaultModelBuildingRequest();
        req.setPomFile(pom);
        req.setModelResolver(new TreeOnly());
        req.setValidationLevel(ModelBuildingRequest.VALIDATION_LEVEL_MINIMAL);
        req.setProcessPlugins(false);
        req.setTwoPhaseBuilding(false);
        req.setLocationTracking(false);
        req.setSystemProperties(sys);
        req.setUserProperties(new Properties());
        req.setActiveProfileIds(profiles);
        return req;
    }

    static void rec(OutputStream out, String... parts) throws IOException {
        for (String p : parts) { out.write(p.getBytes(StandardCharsets.UTF_8)); out.write(0); }
    }

    public static void main(String[] argv) throws Exception {
        File outdir = new File(argv[0]);
        outdir.mkdirs();
        List<String> profiles = argv.length > 1 && !argv[1].isEmpty() ? Arrays.asList(argv[1].split(",")) : List.of();
        String in = new String(System.in.readAllBytes(), StandardCharsets.UTF_8);
        List<String> paths = new ArrayList<>();
        for (String p : in.split("\0")) if (!p.isEmpty()) paths.add(p);
        MavenXpp3Reader reader = new MavenXpp3Reader();
        for (String p : paths) {
            try (Reader r = Files.newBufferedReader(Paths.get(p), StandardCharsets.UTF_8)) {
                Model m = reader.read(r, false);
                Parent par = m.getParent();
                String g = m.getGroupId() != null ? m.getGroupId() : par != null ? par.getGroupId() : null;
                String v = m.getVersion() != null ? m.getVersion() : par != null ? par.getVersion() : null;
                POOL.putIfAbsent(g + ":" + m.getArtifactId() + ":" + v, new File(p));
            } catch (Exception e) { /* unreadable here: its own build reports it */ }
        }
        ModelBuilder builder = new DefaultModelBuilderFactory().newInstance();
        Properties sys = new Properties();
        sys.putAll(System.getProperties()); // the JVM's: java.version, os.* — no env, as offline as we are
        OutputStream out = new BufferedOutputStream(System.out);
        int n = 0;
        for (String p : paths) {
            DefaultModelBuildingRequest req = request(new File(p), sys, profiles);
            try {
                Model eff = builder.build(req).getEffectiveModel();
                File f = new File(outdir, (n++) + ".xml");
                try (Writer w = Files.newBufferedWriter(f.toPath(), StandardCharsets.UTF_8)) { new MavenXpp3Writer().write(w, eff); }
                rec(out, "OK", p, f.getPath());
            } catch (ModelBuildingException e) {
                String msg = "";
                boolean onlyOffline = true;
                for (ModelProblem pr : e.getProblems()) {
                    if (pr.getSeverity() == ModelProblem.Severity.WARNING) continue;
                    if (msg.isEmpty()) msg = pr.getMessage();
                    if (pr.getMessage() == null || !pr.getMessage().contains(OFFLINE)) onlyOffline = false;
                }
                // ★ PARTIAL: when the ONLY errors are imports this oracle may not fetch, Maven has still
                // assembled the model — without those BOMs' entries, which is the frontier cartograph
                // names too. Anything else (a missing parent, a real error) stays an error.
                // ⚠ AND ONLY WHEN EVERY IN-TREE BOM IT IMPORTS BUILDS IN FULL: an import that fails INSIDE an
                // in-tree BOM makes Maven drop that whole BOM, while cartograph keeps its in-tree entries
                // (quarkus-bom: 1231 entries ours, 1182 Maven's) — not the same frontier, so not comparable.
                // (Maven re-reports the nested failure under the NESTED BOM's name, so the message alone
                // cannot tell; each in-tree import is built on its own instead, memoised.)
                ModelBuildingResult res = e.getResult();
                Model eff = res != null ? res.getEffectiveModel() : null;
                if (onlyOffline && eff != null) {
                    for (String id : res.getModelIds()) {
                        Model raw = res.getRawModel(id);
                        if (raw == null || raw.getDependencyManagement() == null) continue;
                        for (Dependency d : raw.getDependencyManagement().getDependencies()) {
                            if (!"import".equals(d.getScope())) continue;
                            for (Map.Entry<String, File> t : POOL.entrySet()) {
                                if (!t.getKey().startsWith(d.getGroupId() + ":" + d.getArtifactId() + ":")) continue;
                                if (!buildsInFull(builder, sys, profiles, t.getValue())) {
                                    onlyOffline = false;
                                    msg = "the in-tree BOM " + t.getKey() + " cannot be built offline, and Maven drops it whole";
                                }
                            }
                        }
                    }
                }
                if (onlyOffline && eff != null) {
                    File f = new File(outdir, (n++) + ".xml");
                    try (Writer w = Files.newBufferedWriter(f.toPath(), StandardCharsets.UTF_8)) { new MavenXpp3Writer().write(w, eff); }
                    rec(out, "PARTIAL", p, f.getPath());
                } else {
                    rec(out, "ERR", p, msg.isEmpty() ? String.valueOf(e.getMessage()) : msg);
                }
            } catch (Exception e) {
                rec(out, "ERR", p, e.toString());
            }
        }
        out.flush();
    }
}
