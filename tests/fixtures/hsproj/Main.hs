module Main where

import Util

main :: IO ()
main = print (run 5)

run :: Int -> Int
run n = go n + limit
  where go k = double k
