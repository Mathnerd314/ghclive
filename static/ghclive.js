function wsLocation() {
    return window.location.href.replace(/^([a-z]+)\:/i, "ws:");
}

var ignoreChange = false;
function handleChange(editor, change) {
    if(ignoreChange) { return; }
    var msgs = doc.replace(change.from, change.to, change.text);
    if(msgs.length > 0) {
        sock.send(JSON.stringify({ actions: msgs }));
    }
}

function refreshEditor() {
    ignoreChange = true;
    // fixme: try to preserve cursor position and selection better if other users insert lines etc
    var sel = cm.somethingSelected();
    var selStart;
    var selEnd;
    var cursor = cm.getCursor();
    if(sel) {
        selStart = cm.getCursor(start);
        selEnd   = cm.getCursor(end);
    }
    cm.setValue(doc.currentVersion());
    cm.setCursor(cursor);
    if(sel) {
        cm.setSelection(selStart,selEnd);
    }
    ignoreChange = false;
}

doc = new Document();

cm = CodeMirror.fromTextArea($('#editor')[0],
                             { mode:         'text/x-haskell'
                               , lineWrapping: true
                               , lineNumbers:  true
                               , fixedGutter:  true
                               , onChange:     handleChange
                             }
                            );
sock = new WebSocket(wsLocation());
sock.onmessage = function(evt) {
    evtJson(evt,function(msg) {
        if(msg.time) {
            updateTimestamp(msg.time);
        }
        var refresh = false;
        var r;
        if(msg.actions) {
            for(var i=0;i<msg.actions.length;i++) {
                var a = msg.actions[i];
                if(a.action === "doc") {
                    doc.setDocument(a.doc);
                    refresh = true;
                } else if(a.action === "clientid") {
                    setClientId(a.clientId);
                } else if(a.action === "insert") {
                    r = doc.applyOp(a);
                    if(r) { refresh = true; }
                } else if(a.action === "remove") {
                    r = doc.applyOp(a);
                    if(r) { refresh = true; }
                }
            }
        }
        if(refresh) {
            refreshEditor();
        }
    });
}

function formatResult (res) {
    var r = $('<div><span class="prompt">hint&gt;</span> <span class="expr">empty expr</span><div class="result"></div></div>');
    r.find('.expr').text(res.expr);
    if(res.error) r.find('.result').text(res.error);
    else r.find('.result').append(res.result.result);
    return r;
}

function scrollToBottom(elem) { // pass in the id of the element you want scrolled to bottom
    var elem = document.getElementById(elem);
    elem.scrollTop = elem.scrollHeight;
}

$(function () {

    // Make the server initialize an empty module in case the user does
    // 'eval it' without entering anything into the editor. Actually we
    // shouldn't need to tell the server to do this, I suppose, so this
    // is a bit of a hack.
    $.get('/loader');

    $("#load").click(function() {
        $.get('/loader');
        return false;
    });

    function evalit() {
        console.log("hey evalit here");
        $.ajax({
            type: "GET",
            url: "/eval",
            data: {expr: $("#expr").val() },
            success: function(res) {
                $("#output").append(formatResult(res));
                scrollToBottom('output');
            }
        }); // end ajax call
        return false;
    }

    $("#evalit").click(evalit);

    $("#outputit").click(function() {
        $.ajax({
            type: "GET",
            url: "/results",
            success: function(results) {
                // clear the output area
                $("#output").empty();
                // map formatResult over the results
                for (var i = 0; i < results.length; i++) {
                    $("#output").append(formatResult(results[i]));
                }
                scrollToBottom('output');
            }
        }); // end ajax call
        return false;
    });
});
