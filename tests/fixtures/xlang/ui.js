function requestThing() {
  chrome.send('getThing', [1]);
}

function requestPromised() {
  return sendWithPromise('getThing');
}
