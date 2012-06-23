
if (typeof console == "undefined" || typeof console.log == "undefined") var console = { log: function() {} }; 

report = alert

function getResult(fileurl, expr){
    var res = null;
    $.ajax({
        url: '/hint',
        type: 'get',
        data : { 'expr':expr,'fileurl':fileurl},
        dataType : 'json',
        async: false,
        success: function(data) {
            res = data;
        }
    });
    return res;
}

$(document).ready(function(){
    $('#fileurl').val('http://www.ScannedInAvian.com/~shae/Demo.hs\nhttp://www.ScannedInAvian.com/~shae/DemoMulti.hs');

    var console1 = $('<div class="console">');
    $('body').append(console1);
    var controller = console1.console({
        welcomeMessage:'Enter Haskell expressions to evaluate.',
        promptLabel: "hint> ",
        commandValidate:function(line){
            if (line == "") return false;
            else return true;
        },

        commandHandle:function(line,report){
            var fileurl = $('#fileurl').val();
            // don't let this name collide with the jquery-console name!
            console.log('inside commandHandle. input is ' + line + ' fileurl is ' + fileurl);
            res = getResult(fileurl,line);
            return res.result;
        },

        autofocus:true,
        animateScroll:true,
        promptHistory:true,
        // welcomeMessage:'Loaded http://www.ScannedInAvian.com/~shae/Demo.hs',
    });
    // controller.promptText('renderDia SVG (SVGOptions "output.file" (Dims 200 200)) (circle 1 # fc red # lw 0 ||| circle 1 # fc green # lw 0 :: Diagram Diagrams.Backend.SVG.SVG R2)');
    controller.promptText('map (+1) [3,5,9]');
});