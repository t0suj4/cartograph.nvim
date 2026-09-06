function requestThing() {
  chrome.send('getThing', [1]);
}

function requestPromised() {
  return sendWithPromise('getThing');
}

// ★ A QUALIFIED SEND: full = 'window.chrome.send', so the binding verb
// 'chrome.send' matches only through verb_matches' THIRD clause (full ENDS WITH
// '.' .. verb) — the one branch nothing else in the suite reached. It is also
// the branch the verb INDEX has to reproduce by keying every dot-suffix.
function requestQualified() {
  window.chrome.send('getThing', [2]);
}
