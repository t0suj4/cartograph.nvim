-- The localhost transport's HTTP request parser: complete-request detection,
-- header lowercasing, Content-Length body framing. Pure — no sockets.

local web = require 'cartograph.webserver'

local CRLF = '\r\n'

test('parse_request: nil until the header terminator arrives', function ()
    eq(nil, web.parse_request('GET / HTTP/1.1' .. CRLF .. 'Host: x'))
end)

test('parse_request: a GET with no body parses', function ()
    local req = web.parse_request('GET /draw HTTP/1.1' .. CRLF .. 'Host: 127.0.0.1:8778' .. CRLF .. CRLF)
    eq('GET', req.method)
    eq('/draw', req.path)
    eq('127.0.0.1:8778', req.headers['host']) -- value keeps its colon; key lowercased
end)

test('parse_request: waits until the whole body has arrived', function ()
    local head = 'POST /paint HTTP/1.1' .. CRLF .. 'Content-Length: 5' .. CRLF .. CRLF
    eq(nil, web.parse_request(head .. 'ab'))       -- only 2 of 5 body bytes
    local req = web.parse_request(head .. 'abcde') -- all 5
    eq('POST', req.method)
    eq('abcde', req.body)
end)

test('parse_request: a grid body (newlines, spaces) survives intact', function ()
    local body = '## #' .. '\n' .. '#  #'
    local raw = 'POST /paint HTTP/1.1' .. CRLF .. 'Content-Length: ' .. #body .. CRLF .. CRLF .. body
    eq(body, web.parse_request(raw).body)
end)

test('canvas_html: is a self-contained page that posts to /paint', function ()
    local html = web.canvas_html()
    ok(html:find('<canvas', 1, true), 'has a canvas element')
    ok(html:find("fetch('/paint'", 1, true), 'posts strokes back to the server')
    ok(not html:find('http://', 1, true) and not html:find('https://', 1, true),
        'no external origins — same-origin only, so no CSP wall')
end)
