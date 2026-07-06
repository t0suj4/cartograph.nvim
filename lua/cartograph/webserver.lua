-- A minimal localhost HTTP server (vim.uv/libuv) — the LIVE BROWSER TRANSPORT.
-- A sandboxed Artifact can't call back to nvim (its CSP blocks every request),
-- so the web canvas is served from HERE instead: a real same-origin page on
-- 127.0.0.1 that POSTs its strokes back to this server, which hands them to a
-- projection surface ([[brush]]). Browser -> localhost -> cartograph -> MCP ->
-- Factorio. Deliberately tiny: one request per connection (Connection: close),
-- Content-Length bodies only (fetch with a string body — no chunked encoding).

local M = {}

local REASON = { [200] = 'OK', [400] = 'Bad Request', [404] = 'Not Found' }

--- Parse an accumulated HTTP request buffer. Returns a request table
--- { method, path, headers = {lowercased}, body } once it is COMPLETE, or nil
--- if more bytes are still needed (headers not terminated, or body < length).
--- Pure — unit-tested without sockets.
function M.parse_request(buf)
    local head_end = buf:find('\r\n\r\n', 1, true)
    if not head_end then return nil end -- headers not complete yet
    local head = buf:sub(1, head_end - 1)
    local method, path = head:match('^(%u+)%s+(%S+)')
    if not method then return nil end
    local headers = {}
    for k, v in head:gmatch('\r\n([^:\r\n]+):[ \t]*([^\r\n]*)') do
        headers[k:lower()] = v
    end
    local clen = tonumber(headers['content-length'] or '0') or 0
    local body_start = head_end + 4
    if #buf - body_start + 1 < clen then return nil end -- body incomplete
    return { method = method, path = path, headers = headers,
        body = buf:sub(body_start, body_start + clen - 1) }
end

--- Start a server on host:port. `handler(req) -> status, content_type, body`
--- is called (on the main loop, so it may touch the store / MCP wire) once a
--- full request arrives. Returns a handle { host, port, close() } or nil, err.
function M.serve(opts)
    local host = opts.host or '127.0.0.1'
    local server = vim.uv.new_tcp()
    local ok, err = pcall(function () server:bind(host, opts.port or 8778) end)
    if not ok then
        pcall(function () server:close() end)
        return nil, ('bind %s:%s failed — %s'):format(host, opts.port or 8778, tostring(err))
    end
    server:listen(64, function (lerr)
        if lerr then return end
        local client = vim.uv.new_tcp()
        server:accept(client)
        local buf = ''
        client:read_start(function (rerr, chunk)
            if rerr or not chunk then
                client:read_stop(); pcall(function () client:close() end); return
            end
            buf = buf .. chunk
            local req = M.parse_request(buf)
            if not req then return end -- await more bytes
            client:read_stop()
            -- handle on the main loop (off the uv read callback) so the handler
            -- can safely drive the MCP wire (vim.wait) without reentrancy
            vim.schedule(function ()
                local okh, status, ctype, body = pcall(opts.handler, req)
                if not okh then status, ctype, body = 500, 'text/plain', tostring(status) end
                body = body or ''
                local resp = ('HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n'
                    .. 'Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n%s'):format(
                    status or 200, REASON[status or 200] or 'OK', ctype or 'text/plain', #body, body)
                pcall(function () client:write(resp, function () pcall(function () client:close() end) end) end)
            end)
        end)
    end)
    local name = server:getsockname()
    return { host = host, port = (name and name.port) or opts.port or 8778,
        close = function () pcall(function () server:close() end) end }
end

--- The self-contained canvas page: draw with the mouse, and every stroke
--- (debounced) POSTs the grid as text ('#' = ink, ' ' = empty) to /paint.
--- Same origin as this server, so no CSP wall.
function M.canvas_html(cols, rows)
    cols, rows = cols or 48, rows or 27
    return ([==[<!doctype html><html><head><meta charset=utf-8>
<title>cartograph · biter canvas</title><style>
body{background:#161616;color:#ddd;font:14px/1.4 monospace;margin:0;display:flex;
flex-direction:column;align-items:center;gap:12px;padding:18px}
canvas{background:#242424;border:1px solid #555;cursor:crosshair;touch-action:none;image-rendering:pixelated}
.bar{display:flex;gap:8px;align-items:center}
button{background:#2f2f2f;color:#ddd;border:1px solid #666;padding:6px 12px;cursor:pointer;font:inherit}
button.on{background:#7a3;color:#111;border-color:#7a3}
#s{color:#8a8;min-width:9em}
</style></head><body>
<h3>cartograph → factorio · dead-biter canvas</h3>
<canvas id=c></canvas>
<div class=bar>
<button id=d class=on>draw</button><button id=e>erase</button>
<button id=x>clear</button><span id=s>ready</span>
</div><script>
const COLS=%d,ROWS=%d,PX=14;
const cv=document.getElementById('c');cv.width=COLS*PX;cv.height=ROWS*PX;
const g=cv.getContext('2d');
const grid=Array.from({length:ROWS},()=>new Array(COLS).fill(0));
let mode=1,down=false,t=null;
function draw(){g.fillStyle='#242424';g.fillRect(0,0,cv.width,cv.height);
g.fillStyle='#c2456a';for(let r=0;r<ROWS;r++)for(let c=0;c<COLS;c++)
if(grid[r][c])g.fillRect(c*PX+1,r*PX+1,PX-2,PX-2);
g.strokeStyle='#333';for(let c=0;c<=COLS;c++){g.beginPath();g.moveTo(c*PX,0);g.lineTo(c*PX,cv.height);g.stroke();}
for(let r=0;r<=ROWS;r++){g.beginPath();g.moveTo(0,r*PX);g.lineTo(cv.width,r*PX);g.stroke();}}
function at(ev){const b=cv.getBoundingClientRect();return[Math.floor((ev.clientX-b.left)/PX),Math.floor((ev.clientY-b.top)/PX)];}
function put(ev){const[c,r]=at(ev);if(r<0||r>=ROWS||c<0||c>=COLS)return;grid[r][c]=mode;draw();sched();}
cv.addEventListener('pointerdown',e=>{down=true;put(e);});
cv.addEventListener('pointermove',e=>{if(down)put(e);});
window.addEventListener('pointerup',()=>{down=false;});
d.onclick=()=>{mode=1;d.className='on';e.className='';};
e.onclick=()=>{mode=0;e.className='on';d.className='';};
x.onclick=()=>{grid.forEach(r=>r.fill(0));draw();sched();};
function sched(){clearTimeout(t);t=setTimeout(send,180);}
function send(){const txt=grid.map(r=>r.map(v=>v?'#':' ').join('')).join('\n');
s.textContent='projecting…';
fetch('/paint',{method:'POST',body:txt}).then(r=>r.text())
.then(_=>{s.textContent='projected ✓';}).catch(err=>{s.textContent='err: '+err;});}
draw();
</script></body></html>]==]):format(cols, rows)
end

return M
