module Helper where

import Diagrams.Prelude
import Diagrams.Backend.SVG
import Text.Blaze.Internal

spike :: Trail R2
spike = fromOffsets . map r2 $ [(1,3), (1,-3)]

burst = mconcat . take 13 . iterate (rotateBy (-1/13)) $ spike

colors = cycle [aqua, orange, deeppink, blueviolet, crimson, darkgreen]

example :: Diagram Diagrams.Backend.SVG.SVG R2
example = lw 1.0 . mconcat  . zipWith lc colors . map stroke . explodeTrail origin $ burst

bar = renderDia SVG (SVGOptions "output.file" (Dims 200 200)) example
