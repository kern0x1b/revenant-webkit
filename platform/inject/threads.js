/*
 * Threads opens a sheet across the screen inviting the visitor to install its
 * app - "Get the full app experience", with an Open Threads button - and on a
 * device where that app does not exist it is a permanent obstruction.
 *
 * It is worse than an obstruction. While the sheet is up the document is one
 * screen tall: scrollHeight reads 460 instead of the feed's 2320, so the page
 * cannot be scrolled at all. Measured on the device, before and after.
 *
 * The first version of this hid the sheet with CSS. That was wrong twice over:
 * the sheet's own elements are ordinary static blocks rather than anything
 * pinned, so the rule matched nothing; and its outermost container IS the page
 * while it is open, so hiding that would leave a blank screen.
 *
 * What works, and what this does, is press the sheet's own close button - the
 * same thing a finger would do. The site then puts the feed back itself, which
 * is how the document returns to its real height. Verified on the device: after
 * the press, scrollHeight goes from 460 to 2080.
 *
 * The press has to be a full sequence. An element.click() alone does nothing
 * here - measured on the device, the sheet stayed up and the document stayed one
 * screen tall - because the site's handler is on the press, not the click. A
 * mousedown, a mouseup and a click, built with document.createEvent and aimed at
 * the control's own centre, dismisses it every time. An earlier version of this
 * file concluded that a page-made event was untrusted and routed the press
 * through the app instead; that was wrong, and the sheet was never being closed
 * at all.
 */
(function () {
    "use strict";

    /* Nothing below this line runs inside a frame that is not the top one.
     *
     * This exists now because of prefetchOtherTabs() further down, which opens
     * other tabs of the site in hidden iframes to warm their bytecode ahead of
     * a real visit. Each iframe is a fresh window with its own __appchromeScript
     * flag, so without this guard the injected script would run again inside
     * it - dismiss-sheet, bottom-bar promotion and all - and promoteBottomBar()
     * would report the hidden iframe's nav to window.appchrome.chrome(), racing
     * the real page's bottom bar with whatever the prefetched tab happens to
     * show. Worse, that inner copy would find the same <nav> shape and start
     * warming tabs of its own, iframe inside iframe, without end. A page that
     * legitimately embeds an iframe of its own is not a case this file has any
     * business touching either way. */
    if (window !== window.top)
        return;

    /* The runtime re-applies this script whenever it cannot tell whether the
     * document still has it - a navigation inside the site replaces everything.
     * Without a guard each re-application starts another copy of the watcher
     * below, and thirty copies of anything that touches the DOM is what a
     * two-frames-per-second page looks like. */
    if (window.__appchromeScript)
        return;
    window.__appchromeScript = true;
    try {

    /* The sheet is found the moment the site inserts it: the observer looks
     * only at what each mutation added, so the check costs nothing while the
     * page is quiet. Nothing here polls, and nothing reads the whole document -
     * an innerText of a full feed serializes every post and was measured
     * blocking the UI thread for seconds at a time.
     *
     * The press itself comes from the app: a page-made dispatchEvent is not a
     * trusted event and the site ignores it. The page only reports where the
     * close control is, in window.__sheetCloseAt. */
    function pressControl(control) {
        var box = control.getBoundingClientRect();
        var x = box.left + box.width / 2;
        var y = box.top + box.height / 2;
        var names = ["mousedown", "mouseup", "click"];
        for (var i = 0; i < names.length; i++) {
            var event = document.createEvent("MouseEvents");
            event.initMouseEvent(names[i], true, true, window, 1, x, y, x, y,
                false, false, false, false, 0, null);
            control.dispatchEvent(event);
        }
    }

    function dismissSheetIfPresent() {
        var dialog = document.querySelector("div[role=dialog]");
        if (!dialog)
            return false;
        /* Not matched on its wording. It used to be: the sheet said "full app
         * experience" and the check looked for exactly that. The site now says
         * "There's more to do, see, and chat about in the app", the check failed,
         * and the sheet was never dismissed - which locks the document to one
         * screen and stops the feed entirely. Measured on the device: with the
         * sheet up the document is 460 px, after it is closed 2425.
         *
         * What identifies it instead is its shape: a dialog that covers most of
         * the screen and carries a control whose own label says it closes. That
         * survives the copy changing again. */
        if (!dialog.querySelector("[aria-label=Close]") && !document.querySelector("[aria-label=Close]"))
            return false;
        var frame = dialog.getBoundingClientRect();
        if (frame.width < 50 || frame.height < 50)
            return false;
        if (frame.bottom < 0 || frame.right < 0 || frame.top > window.innerHeight || frame.left > window.innerWidth)
            return false;

        /* Only a control that says it closes something is pressed. Guessing by
         * position - "small, top left" - hit the logo and the sign-in button
         * instead once the sheet changed shape, and pressing an unknown control
         * on someone's behalf is worse than leaving the sheet up.
         *
         * The control is looked for across the document rather than inside the
         * dialog: the second time the sheet appears it is thirteen nodes with
         * one link in them and the cross sits above it in the page. */
        var candidates = dialog.querySelectorAll("[aria-label=Close]");
        if (!candidates.length)
            candidates = document.querySelectorAll("[aria-label=Close]");
        for (var i = 0; i < candidates.length; i++) {
            var box = candidates[i].getBoundingClientRect();
            if (box.width < 8 || box.height < 8)
                continue;
            if (box.top < 0 || box.left < 0 || box.bottom > window.innerHeight || box.right > window.innerWidth)
                continue;
            pressControl(candidates[i]);
            return true;
        }
        return false;
    }

    /* The dialog and its close control arrive in separate mutations, and once
     * the sheet is fully up the page goes quiet - a single check after the
     * last mutation looks too early and then never looks again. So each burst
     * of mutations buys a short series of looks, which ends as soon as the
     * position is reported or there is no dialog left to look at. */
    /* The sheet comes back: this site raises it again whenever a signed-out
     * reader scrolls. So there is no budget of attempts - while it is up, look
     * again; when it is gone, stop entirely and wait for the page to change.
     * Both halves matter: the looking costs a selector match and one rect while
     * the document is a single screen tall, and the not-looking is what keeps
     * a quiet page quiet. */
    var lookTimer = 0;

    /* Turning "get the app" into "log in".
     *
     * Asking someone to sign in is a reasonable thing for a site to do; sending
     * them to an app store from inside an app is not, and on this device that
     * app does not exist at all, so every one of those buttons is a dead end.
     * The label is rewritten where it can be, and the press is redirected in a
     * capture-phase listener regardless - a listener survives the re-render
     * that would undo an edited href.
     */
    var appPromptWords = ["open threads", "get app", "get the app", "download", "use the app", "open in app"];

    function looksLikeAppPrompt(text) {
        /* Measured against the raw string first. textContent of a control that
         * turns out to be a whole post is the feed serialized, and trimming and
         * lowercasing it made two more copies of that before the length test
         * threw all three away. */
        if (!text || text.length > 200)
            return false;
        var lowered = text.trim().toLowerCase();
        if (!lowered || lowered.length > 40)
            return false;
        for (var i = 0; i < appPromptWords.length; i++) {
            if (lowered.indexOf(appPromptWords[i]) >= 0)
                return true;
        }
        return false;
    }

    /* Every candidate is marked, not only the ones that matched.
     *
     * The mark used to go on matches alone, so each pass read textContent for
     * every control on the page again - and on this feed that grows without
     * bound while the pass repeats every 800 ms. Marking on sight makes the
     * scan cost what has been added since the last one. A control's own label
     * does not become the app pitch later; the capture-phase listener above is
     * what catches a press whose label was rewritten under us. */
    function retargetAppPrompts() {
        var candidates = document.querySelectorAll("a, div[role=button], button");
        for (var i = 0; i < candidates.length; i++) {
            var element = candidates[i];
            if (element.getAttribute("data-appchrome-retargeted"))
                continue;
            var text = element.textContent;
            /* An element with no label yet is left unmarked: the site fills some
             * of them in a later commit, and marking one while it is empty - or
             * while it holds nothing but whitespace - would skip it for good.
             * Anything past the length looksLikeAppPrompt will consider is
             * marked without trimming it, because trimming a whole serialized
             * post is the cost this marking exists to avoid. */
            if (text && (text.length > 200 || text.trim()))
                element.setAttribute("data-appchrome-retargeted", "1");
            if (!looksLikeAppPrompt(text))
                continue;
            if (element.tagName === "A")
                element.setAttribute("href", "/login");
            var label = element.querySelector("span, div");
            if (label && !label.children.length)
                label.textContent = "Log in";
            else if (!element.children.length)
                element.textContent = "Log in";
        }
    }

    /* Only a control whose own label is the app pitch is redirected. Walking up
     * and matching on textContent caught whole containers - a tap anywhere in a
     * post whose subtree happened to contain those words went to the sign-in
     * page, which is worse than the button it was fixing. */
    document.addEventListener("click", function (event) {
        var element = event.target;
        for (var n = 0; n < 4 && element; n++) {
            if (element.nodeType === 1) {
                var isControl = element.tagName === "A" || element.tagName === "BUTTON"
                    || element.getAttribute("role") === "button";
                if (isControl && looksLikeAppPrompt(element.textContent)) {
                    event.preventDefault();
                    event.stopPropagation();
                    location.href = "/login";
                    return;
                }
            }
            element = element.parentElement;
        }
    }, true);

    var pressesForThisSheet = 0;
    var looksLeft = 40;

    function look() {
        lookTimer = 0;

        /* This stops. It did not, and that was the single most expensive thing
         * on the page.
         *
         * The install sheet appears within the first seconds or not at all, and
         * the bottom bar is decided once. But look() rescheduled itself forever
         * and a MutationObserver over the whole document rescheduled it again on
         * every mutation - and an infinite feed mutates continuously, so this ran
         * a querySelectorAll over a growing document several times a second for
         * the life of the session. Measured on the device by launching with an
         * empty injected script: with this file the web thread burned 71-79
         * seconds of processor in a one minute session, without it 2-8.
         *
         * Forty passes is about half a minute, which is far longer than the sheet
         * takes to appear. While a dialog is actually up the count is refreshed,
         * so a sheet that arrives late is still dismissed. */
        if (looksLeft <= 0) {
            if (observer)
                observer.disconnect();
            return;
        }
        looksLeft--;
        /* Before the early return: the bar has to be handed over whether or not a
         * sheet happens to be up, and it only appears once the feed has rendered,
         * which is after the first look. */
        promoteBottomBar();
        if (!document.querySelector("div[role=dialog]")) {
            pressesForThisSheet = 0;
            lookTimer = window.setTimeout(look, 800);
            return;
        }
        retargetAppPrompts();
        looksLeft = 40;
        if (pressesForThisSheet < 3 && dismissSheetIfPresent())
            pressesForThisSheet++;
        lookTimer = window.setTimeout(look, 800);
    }

    function scheduleLook() {
        if (!lookTimer)
            lookTimer = window.setTimeout(look, 300);
    }

    /* A record of requests that fail, kept for one question.
     *
     * Logging in reports only "something went wrong", which says nothing about
     * which request failed or how. This keeps the last few failures and any
     * unhandled error on the window, where the runtime can read them after the
     * fact.
     *
     * Off unless the page is asked for it with ?__netlog=1, and called once.
     * It sat inside look(), after the check for the sheet, so every pass while a
     * sheet was up - one every 800 ms, and this site raises the sheet again on
     * every scroll - wrapped fetch and XMLHttpRequest in another layer and
     * started another MutationObserver over the whole document that nothing ever
     * disconnected. This file's own header says what that costs: the web thread
     * burned 71-79 seconds of processor in a one minute session. */
    function recordFailures() {
        window.__netFails = [];
        /* Kept across a navigation as well as in memory: the failure and the
         * page that shows it are often on opposite sides of one. */
        function note(entry) {
            if (window.__netFails.length < 8)
                window.__netFails.push(entry);
            try {
                var stored = JSON.parse(localStorage.getItem("__loginWatch") || "[]");
                if (stored.length < 24) {
                    stored.push(entry);
                    localStorage.setItem("__loginWatch", JSON.stringify(stored));
                }
            } catch (error) { }
        }
        var originalFetch = window.fetch;
        if (originalFetch) {
            window.fetch = function (input, init) {
                var url = (typeof input === "string" ? input : (input && input.url) || "").slice(0, 90);
                return originalFetch.apply(this, arguments).then(function (response) {
                    if (!response.ok)
                        note("fetch " + response.status + " " + url);
                    return response;
                }, function (error) {
                    note("fetch failed " + url + " " + String(error && error.message).slice(0, 60));
                    throw error;
                });
            };
        }
        var open = XMLHttpRequest.prototype.open;
        var send = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (method, url) {
            this.__recordedUrl = String(url).slice(0, 90);
            return open.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function () {
            var request = this;
            this.addEventListener("load", function () {
                if (request.status >= 400)
                    note("xhr " + request.status + " " + request.__recordedUrl);
            });
            this.addEventListener("error", function () {
                note("xhr failed " + request.__recordedUrl);
            });
            return send.apply(this, arguments);
        };
        window.addEventListener("unhandledrejection", function (event) {
            note("rejected " + String((event.reason && (event.reason.message || event.reason)) || "").slice(0, 90));
        });

        /* Anything the page puts on screen that reads like a failure. Logging in
         * reports only "something went wrong" and leaves no trace anywhere else,
         * so the text itself is worth keeping. */
        if (window.MutationObserver) {
            new MutationObserver(function (records) {
                for (var i = 0; i < records.length; i++)
                    for (var j = 0; j < records[i].addedNodes.length; j++) {
                        var text = (records[i].addedNodes[j].textContent || "").trim();
                        if (text && text.length < 140 && /wrong|Error|error|try again|Sorry/.test(text))
                            note("shown: " + text.slice(0, 120));
                    }
            }).observe(document.documentElement, {childList: true, subtree: true});
        }
    }


    /* Letting the engine stop laying out what the reader has gone past.
     *
     * The engine lays out a subtree instead of the whole document only below a
     * layout boundary, and RenderObject.cpp grants that only to a renderer with
     * both layout and size containment. A feed post has neither, so every change
     * walks up to the RenderView. Asked to report every pass, the engine says all
     * of them are whole-document, and the cost is the blocks walked: 1783 blocks
     * and 548 ms at a document of 5000 px, 9529 and 2726 ms at 7900 px.
     *
     * content-visibility: auto gives both kinds of containment while the element
     * is far from the screen and drops them when it comes near, so a post the
     * reader has gone past stops being laid out and the same post scrolled back
     * to behaves normally. contain-intrinsic-size carries "auto", so a skipped
     * post keeps the height it last had and the page does not jump.
     *
     * Only posts already off the top, and only a screen past it. An earlier
     * version marked every post in the container, including those below the
     * screen: the feed's own sentinel for loading more sits down there, a skipped
     * subtree is not observed, and the document stopped growing past ~5300 px
     * where it otherwise reaches ~8900. Nothing below the fold is touched.
     *
     * Emptying posts outright was also tried - keeping their markup as a string,
     * pinning their height - and it works and restores correctly, but compared at
     * the same document size it is a loss: 3499 blocks and 955 ms against 1783
     * and 548, because emptying and restoring dirties the tree and forces the
     * whole-document layout it was meant to avoid.
     *
     * Marking is one-way. The engine decides on its own when a marked post is
     * near enough to lay out again. */
    var feedStyle = null;
    var markedFeed = null;

    /* Not called: the engine applies this itself now, in StyleAdjuster, for any
     * site rather than for this one. Kept because it is what proved the idea. */
    function skipScrolledPastPosts() {
        if (!feedStyle) {
            feedStyle = document.createElement("style");
            feedStyle.id = "__cvskip";
            feedStyle.appendChild(document.createTextNode(
                "[data-cvpast]{content-visibility:auto;contain-intrinsic-size:auto 320px}"));
            (document.head || document.documentElement).appendChild(feedStyle);
        }

        /* document.contains, not parentNode: a node the site has swapped out
         * keeps its old parent, so parentNode stays truthy forever and the mark
         * would sit on a subtree that is no longer on the page. */
        if (!markedFeed || !document.contains(markedFeed)) {
            markedFeed = findFeed();
            if (!markedFeed)
                return;
        }

        var kids = markedFeed.children;
        var marked = 0;
        for (var i = 0; i < kids.length; i++) {
            if (kids[i].hasAttribute("data-cvpast")) {
                marked++;
                continue;
            }
            if (kids[i].getBoundingClientRect().bottom < -window.innerHeight) {
                kids[i].setAttribute("data-cvpast", "");
                marked++;
            }
        }
        window.__cvPast = marked;
        window.__cvPosts = kids.length;
    }

    /* The feed, found from a point on the screen rather than from a guess about
     * the markup. Walking down from the body by "tallest child" was tried and
     * picked the innards of a single post. elementFromPoint lands inside a real
     * post; the first ancestor with several children of its own is the list that
     * holds them. Nothing here matches a class name: Threads generates those. */
    function findFeed() {
        var node = document.elementFromPoint(Math.round(window.innerWidth / 2),
            Math.round(window.innerHeight * 0.6));
        var climbed = 0;
        while (node && node !== document.body && climbed < 30) {
            var parent = node.parentElement;
            if (!parent)
                return null;
            if (parent.children.length >= 5 && node.getBoundingClientRect().height > 60)
                return parent;
            node = parent;
            climbed++;
        }
        return null;
    }

    /* Handing the site's bottom bar to the system.
     *
     * A position:fixed bar sits inside the layer UIKit slides when it scrolls,
     * so holding it still means moving it the other way on every frame - and the
     * two movements are decided by different systems in different transactions.
     * Reported to the application and hidden here, the bar is drawn as real
     * views outside the web view, where nothing can shift it and the engine has
     * one fewer composited layer to carry on every scroll.
     *
     * Only reported when it is actually found; a page whose bar this does not
     * match keeps its own, unchanged. */
    var chromeReported = false;

    function promoteBottomBar() {
        if (chromeReported || !window.appchrome || !window.appchrome.chrome)
            return;

        /* Off until the native bar can draw what the site draws.
         *
         * The site's bar is five icons. What is handed over is five strings -
         * the labels of those icons - so the native bar came out as five words
         * where the reader expects pictures. Replacing something with a worse
         * copy of it is not a promotion, so the page keeps its own bar until the
         * icons themselves are carried across. */
        if (!window.__appchromeNativeBar)
            return;

        var nav = null;
        var candidates = document.querySelectorAll("nav");
        for (var i = 0; i < candidates.length; i++) {
            var style = window.getComputedStyle(candidates[i]);
            if (style.position !== "fixed")
                continue;
            var box = candidates[i].getBoundingClientRect();
            if (box.height < 30 || box.width < window.innerWidth * 0.8)
                continue;
            if (box.top < window.innerHeight * 0.5)
                continue;
            nav = candidates[i];
            break;
        }
        if (!nav)
            return;

        var items = [];
        var links = nav.querySelectorAll("a[href]");
        for (var l = 0; l < links.length && items.length < 6; l++) {
            var icon = links[l].querySelector("svg[aria-label]");
            items.push({
                href: links[l].getAttribute("href"),
                label: icon ? icon.getAttribute("aria-label") : (links[l].getAttribute("aria-label") || "")
            });
        }
        /* Only when the whole bar can be reproduced. Threads draws five items and
         * only two of them are links; a native bar with two icons where the site
         * has five is worse than the one it replaces, so in that case the page
         * keeps its own - which is what the design calls for when the selectors
         * do not match. */
        var visible = nav.querySelectorAll("a[href], [role=button]").length;
        if (items.length < 4 || items.length < visible)
            return;

        window.appchrome.chrome(JSON.stringify({bottom: items}));
        nav.style.setProperty("display", "none", "important");
        chromeReported = true;
    }

    /* Warming the other tabs' bytecode while the reader is doing nothing that
     * competes for it.
     *
     * The first visit to a route costs 3-5s of parse and compile that later
     * visits do not pay, because JSC's bytecode cache is disk-backed and keyed
     * off the script's own source - patches/engine/03-javascriptcore.patch's
     * AheadOfTimeBytecodeThread hands the compiled blob to the SourceProvider,
     * not to whichever frame happened to ask for it. So a hidden iframe that
     * loads a tab's real href and is left to run the site's own JavaScript to
     * completion warms exactly the cache entries a real tap on that tab would
     * need, and does not care what bundler or router produced them: it is the
     * same browser primitive <Link prefetch> and a background import() build
     * on, not anything reached through Threads' own __d/requireLazy loader.
     * requireLazy was the first idea, and Meta's own docs describe it as a
     * real promise-returning API - but reaching a specific route through it
     * needs that route's module ID pulled out of BTLDR's table, which is
     * Threads-specific and would have to be rediscovered by hand for
     * anything else this wrapper ever points at. This was NOT confirmed
     * against the live page - device access was not exercised while writing
     * this, for reasons in the change notes - so treat "requireLazy has a
     * usable hook" as an unverified lead, not a finding. The iframe needs
     * nothing but the <a href> already sitting in the bar, on any site.
     *
     * Nothing here has been measured on a device: it is built from reading the
     * cache's engine patch, not from watching BYTECODE totals move. Off unless
     * asked for with ?__prefetchtabs=1, until it has. */
    function prefetchOtherTabs() {
        var idle = window.requestIdleCallback
            ? function (fn) { window.requestIdleCallback(fn, {timeout: 4000}); }
            : function (fn) { window.setTimeout(fn, 3000); };

        /* Same shape as promoteBottomBar()'s search, on purpose: a fixed bar
         * pinned to the bottom half of the screen. Run independently of it,
         * though - promoteBottomBar only reports a bar once __appchromeNativeBar
         * is on, and warming the other tabs should not wait on a flag that is
         * about something else entirely. */
        var nav = null;
        var candidates = document.querySelectorAll("nav");
        for (var i = 0; i < candidates.length; i++) {
            var style = window.getComputedStyle(candidates[i]);
            if (style.position !== "fixed")
                continue;
            var box = candidates[i].getBoundingClientRect();
            if (box.height < 30 || box.width < window.innerWidth * 0.8)
                continue;
            if (box.top < window.innerHeight * 0.5)
                continue;
            nav = candidates[i];
            break;
        }
        if (!nav)
            return;

        var hrefs = [];
        var links = nav.querySelectorAll("a[href]");
        for (var l = 0; l < links.length; l++) {
            var href = links[l].getAttribute("href");
            /* Only a same-site path. A bare "/" or the current tab buys
             * nothing, and anything not starting with "/" is either a
             * fragment or another origin, neither of which this should touch
             * from a hidden iframe on the reader's behalf. */
            if (!href || href.charAt(0) !== "/" || href === location.pathname)
                continue;
            if (hrefs.indexOf(href) < 0)
                hrefs.push(href);
        }
        if (!hrefs.length)
            return;

        var next = 0;
        function warmOne() {
            if (next >= hrefs.length)
                return;
            var href = hrefs[next++];
            var frame = document.createElement("iframe");
            frame.setAttribute("aria-hidden", "true");
            frame.setAttribute("tabindex", "-1");
            /* visibility:hidden and off-screen, not display:none - a couple of
             * engines skip loading a display:none iframe's contents entirely,
             * which would compile nothing. 1x1 rather than 0x0 for the same
             * reason: some layout code treats a zero-area frame as not really
             * there. */
            frame.style.cssText = "position:absolute;left:-9999px;top:0;"
                + "width:1px;height:1px;border:0;visibility:hidden;pointer-events:none";

            var settled = false;
            function done() {
                if (settled)
                    return;
                settled = true;
                if (frame.parentNode)
                    frame.parentNode.removeChild(frame);
                idle(warmOne);
            }
            /* load fires once the tab's own HTML has finished, which on a
             * client-rendered route is before its JavaScript has necessarily
             * compiled and run everything it is going to. The extra pause
             * after it is a guess at how long that tail takes, not a
             * measurement - the number to revisit once BYTECODE totals can be
             * read across this. Either way something tears the iframe down:
             * the timeout below covers a tab whose load event never fires at
             * all, so one bad route cannot stall every tab behind it. */
            frame.addEventListener("load", function () { window.setTimeout(done, 1500); });
            (document.body || document.documentElement).appendChild(frame);
            frame.src = href;
            window.setTimeout(done, 8000);
        }
        idle(warmOne);
    }

    /* The observer watches for the sheet arriving, and is disconnected with the
     * rest of this once the page has settled. Without the disconnect it delivers
     * a callback for every node an infinite feed appends, forever. */
    var observer = null;
    if (window.MutationObserver) {
        observer = new MutationObserver(scheduleLook);
        observer.observe(document.documentElement, {childList: true, subtree: true});
    }

    retargetAppPrompts();
    promoteBottomBar();
    scheduleLook();
    if (/[?&]__netlog=1/.test(location.search))
        recordFailures();
    if (/[?&]__prefetchtabs=1/.test(location.search))
        window.setTimeout(prefetchOtherTabs, 4000);

    window.__appchromeReady = true;
    /* Where the page's own time goes, when asked for it.
     *
     * The engine's profiler says JavaScript, and the page's JavaScript is not
     * ours to read - but every long piece of it is entered through one of a
     * handful of doors: a timer, an animation frame, an observer, or the
     * message channel a scheduler uses to keep working across tasks. Counted
     * here, from before the page's own scripts run, they say which door.
     *
     * Off unless the page is asked for it, and it is asked for by loading with
     * ?__cost=1, so nothing measures itself in ordinary use. */
    try {
        if (/[?&]__cost=1/.test(location.search)) {
            window.__cost = {};
            var account = function (kind, ms) {
                var c = window.__cost[kind] || { calls: 0, ms: 0, worst: 0 };
                c.calls++; c.ms += ms;
                if (ms > c.worst) c.worst = ms;
                window.__cost[kind] = c;
            };
            var time = function (kind, fn, self, args) {
                var started = Date.now();
                try { return fn.apply(self, args); }
                finally { account(kind, Date.now() - started); }
            };

            var rAF = window.requestAnimationFrame;
            window.requestAnimationFrame = function (fn) {
                return rAF.call(window, function (t) { return time('animation frame', fn, window, [t]); });
            };
            var timeout = window.setTimeout;
            window.setTimeout = function (fn, delay) {
                if (typeof fn !== 'function') return timeout.apply(window, arguments);
                return timeout.call(window, function () { return time('timer', fn, window, []); }, delay);
            };
            var interval = window.setInterval;
            window.setInterval = function (fn, delay) {
                if (typeof fn !== 'function') return interval.apply(window, arguments);
                return interval.call(window, function () { return time('repeating timer', fn, window, []); }, delay);
            };
            if (window.IntersectionObserver) {
                var IO = window.IntersectionObserver;
                window.IntersectionObserver = function (callback, options) {
                    return new IO(function (entries, observer) {
                        return time('intersection observer', callback, window, [entries, observer]);
                    }, options);
                };
            }
            if (window.MutationObserver) {
                var MO = window.MutationObserver;
                window.MutationObserver = function (callback) {
                    return new MO(function (records, observer) {
                        return time('mutation observer', callback, window, [records, observer]);
                    });
                };
            }
            /* The scheduler's door. React posts a message to itself to continue work
             * in a later task, so a single one of these can be seconds long. */
            var portDescriptor = window.MessagePort
                && Object.getOwnPropertyDescriptor(MessagePort.prototype, 'onmessage');
            if (portDescriptor && portDescriptor.set) {
                Object.defineProperty(MessagePort.prototype, 'onmessage', {
                    configurable: true, get: portDescriptor.get,
                    set: function (fn) {
                        if (typeof fn !== 'function') return portDescriptor.set.call(this, fn);
                        var port = this;
                        return portDescriptor.set.call(this, function (event) {
                            return time('scheduler', fn, port, [event]);
                        });
                    }
                });
            }
            var addListener = EventTarget.prototype.addEventListener;
            EventTarget.prototype.addEventListener = function (type, listener, options) {
                if (typeof listener === 'function' && (type === 'message' || type === 'scroll' || type === 'touchmove')) {
                    var self = this;
                    return addListener.call(this, type, function (event) {
                        return time('listener: ' + type, listener, self, [event]);
                    }, options);
                }
                return addListener.apply(this, arguments);
            };
        }
    } catch (costError) {
        /* The accounting is a measurement aid; if the engine will not let it
         * wrap something, the page must still get its chrome. */
        window.__costError = String(costError);
    }

    window.__appchromeV = 36;
    } catch (error) {
        window.__appchromeError = String(error && error.message || error);
    }
})();
