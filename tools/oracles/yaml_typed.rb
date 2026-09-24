# ORACLE for yamlvalue's `psych-safe` profile (CART-1053): what Psych loads, per document, through
# the SAFE path (a restricted class loader) with aliases allowed and Date/Time/Symbol permitted —
# `YAML.safe_load`'s defaults would REFUSE those, which is a divergence of its own, noted, not joined.
# Canonical form as yamlvalue.typed(). NUL-separated paths on stdin; JSON on stdout.
require 'psych'
require 'json'
require 'date'

def canon(v)
  case v
  when nil then 'null'
  when true then 'bool:true'
  when false then 'bool:false'
  when Integer then 'int:' + (v.abs >= 2**53 ? 'big' : v.to_s)
  when Float
    return 'float:nan' if v.nan?
    return 'float:' + (v > 0 ? 'inf' : '-inf') if v.infinite?
    return 'float:-0' if v.zero? && (1.0 / v) < 0
    'float:' + format('%.17g', v)
  when Date, Time, DateTime then 'timestamp'
  when Symbol then 'symbol:' + v.to_s
  when String then 'str:' + v
  when Hash then { '__o' => v.map { |k, x| c = canon(k); [c.is_a?(String) ? c : JSON.generate(c), canon(x)] } }
  when Array then { '__a' => v.map { |x| canon(x) } }
  else 'unknown:' + v.class.to_s
  end
end

out = {}
STDIN.read.split("\0").each do |p|
  next if p.empty?
  begin
    loader = Psych::ClassLoader::Restricted.new(%w[Date Time DateTime Symbol], [])
    scanner = Psych::ScalarScanner.new(loader, strict_integer: false)
    visitor = Psych::Visitors::ToRuby.new(scanner, loader)
    docs = Psych.parse_stream(File.read(p, encoding: 'UTF-8')).children.map { |d| canon(visitor.accept(d)) }
    out[p] = { 'value' => { '__a' => docs } }
  rescue Exception => e
    out[p] = { 'error' => "#{e.class}: #{e.message}".gsub("\n", ' ')[0, 200] }
  end
end
STDOUT.write(JSON.generate(out))
