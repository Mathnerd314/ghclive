ghclive
=======

Google Summer of Code 2012 project, GHCi for the web

Prototypes
----------
The prototypes subdirectory contains several quick hacks demonstrating various concepts.

* [hintdownloadexecute](ghclive/prototypes/hintdownloadexecute) is hint's [example.hs](http://code.haskell.org/hint/devel/examples/examples.hs) modified to download and execute Demo.main from http://www.scannedinavian.com/~shae/Demo.hs .
* [scottywebexecute](ghclive/prototypes/scottywebexecute) is the basic.hs example from [scotty](https://github.com/xich/scotty/) modified only slightly to prove to myself that I understand the code.
* [hintdownloadexecute](ghclive/prototypes/hintdownloadexecute) is the front end from http://haskell.handcraft.com/ modified to have scotty and hint as a backend instead of calling tryhaskell.org.
* [scottyjsonclock](ghclive/prototypes/scottyjsonclock) was a quick refresher for how AJAX works in Haskell.
* [hintpostexecute](ghclive/prototypes/hintpostexecute) uses all the previous prototypes to give a very basic ghci in the browser with Main.hs loaded from any http URL
* [jqueryconsole](ghclive/prototypes/jqueryconsole) extends the above prototypes to use [Chris Done](https://github.com/chrisdone/)‘s [jquery-console](https://github.com/chrisdone/jquery-console) as famously seen in [tryhaskell.org](http://tryhaskell.org/), giving a more GHCi-like result
* [jqueryraw](ghclive/prototypes/jqueryraw) is much simpler in that it uses jquery but not jquery-console.
