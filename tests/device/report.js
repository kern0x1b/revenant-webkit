// Collects a page's verdicts and reports them in one request.
//
// The device cannot be asked for its DOM, so each page reports itself: the
// runner serves these pages from a plain HTTP server and reads the verdicts out
// of that server's own request log. One request per page rather than one per
// check, because a page that finishes while requests are still queued loses
// them - which is exactly what happened with one request per check.
(function () {
    var page = document.title || 'page';
    var verdicts = [];

    window.report = function (name, pass, detail) {
        verdicts.push((pass ? 'PASS' : 'FAIL') + '|' + name + '|' + String(detail === undefined ? '' : detail));
        var line = document.createElement('div');
        line.textContent = (pass ? 'PASS ' : 'FAIL ') + name + '  ' + (detail === undefined ? '' : detail);
        line.style.color = pass ? '#060' : '#a00';
        document.body.appendChild(line);
    };

    window.reportDone = function () {
        var url = '/verdicts?page=' + encodeURIComponent(page) + '&results=' + encodeURIComponent(verdicts.join('~~'));
        new Image().src = url + '&t=' + Date.now();
    };
})();
