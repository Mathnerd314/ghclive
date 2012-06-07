
// what's the problem?

if (typeof console == "undefined" || typeof console.log == "undefined") var console = { log: function() {} }; 


function evalHs(fileurl, expr, success) {
    var data = { 'method': 'eval', 'fileurl': fileurl, 'expr': expr };
    var call = {
        'url' : '/hint',
        'data' : data,
        'dataType' : 'json',
        'jsonp' : 'pad',
        'success' : success,
        'error' : function() { alert("error"); },
    };
    console.log(call);
    $.ajax(call);

}

function output(s) {
    if (s) {
        $('#output').val($('#output').val() + s + '\n');
    }
    var outputEl = document.getElementById('output');
    outputEl.scrollTop = outputEl.scrollHeight - outputEl.clientHeight;
}

$(function() {
    $('#expr').focus();
    output();
    $('form').submit(function() {
        var fileurl = $('#fileurl').val();
        var expr = $('#expr').val();
        $('#expr').val('');
        output('> ' + expr);
        evalHs(fileurl, expr, function(result) {
            if (console) {
                console.log(result);
            }
            output(result.result);
            if (result.type) {
                output(':: ' + result.type);
            }
            if (result.result && result.result.length == 1024) {
                output('(The result is too long, so I truncated it for you.)');
            }
            output(result.error);
            output(result.exception);
        });
        return false;
    });
    // fill in the default field values
    $('#fileurl').val('http://www.ScannedInAvian.com/~shae/Demo.hs');
    $('#expr').val('map (+1) [1,3,5] -- expression, hint enter at the end of this line');
});
