// CloudFront Function, viewer-request, on the website's distribution.
//
// The origin is S3's private REST endpoint (OAC), which serves exactly the key
// it is asked for: /anime/ is not /anime/index.html, so without this every
// page but the root 403s. Astro builds directory-style pages
// (anime/index.html), and links to them as /anime/.
//
//   /anime/     -> rewritten to /anime/index.html (no redirect, same URL)
//   /anime      -> 301 to /anime/ (one canonical URL per page)
//   /style.css  -> untouched (has an extension)
function handler(event) {
  var request = event.request;
  var uri = request.uri;

  if (uri.endsWith('/')) {
    request.uri = uri + 'index.html';
    return request;
  }

  var last = uri.substring(uri.lastIndexOf('/') + 1);
  if (last.indexOf('.') === -1) {
    var qs = '';
    var keys = Object.keys(request.querystring);
    if (keys.length > 0) {
      qs = '?' + keys.map(function (k) {
        var v = request.querystring[k];
        return v.value === '' ? k : k + '=' + v.value;
      }).join('&');
    }
    return {
      statusCode: 301,
      statusDescription: 'Moved Permanently',
      headers: { location: { value: uri + '/' + qs } },
    };
  }

  return request;
}
