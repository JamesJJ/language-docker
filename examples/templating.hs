{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}

import Control.Monad
import Language.Docker
import Language.Docker.Syntax

tags :: [String]
tags = ["7.8", "7.10", "8"]

cabalSandboxBuild packageName = do
    let cabalFile = packageName ++ ".cabal"
    run "cabal sandbox init"
    run "cabal update"
    add [SourcePath cabalFile] (TargetPath $ "/app/" ++ cabalFile)
    run "cabal install --only-dep -j"
    add ["."] "/app/"
    run "cabal build"

main =
    forM_ tags $ \tag -> do
        let df =
                toDockerfileStr $ do
                    from ("haskell" `tagged` tag)
                    cabalSandboxBuild "mypackage"
        writeFile ("./examples/templating-" ++ tag ++ ".dockerfile") df
