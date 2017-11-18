module Language.Dockerfile.ParserSpec where

import Data.List (find)
import Data.Maybe (fromMaybe, isJust)

import Language.Dockerfile.Normalize
import Language.Dockerfile.Parser
import Language.Dockerfile.Rules
import Language.Dockerfile.Syntax

import Test.HUnit
import Test.Hspec
import Text.Parsec

spec :: Spec
spec = do
        describe "parse FROM" $
            it "parse untagged image" $ assertAst "FROM busybox" [From (UntaggedImage "busybox")]
        describe "parse ENV" $ do
            it "parses unquoted pair" $ assertAst "ENV foo=bar" [Env [("foo", "bar")]]
            it "parse with space between key and value" $
                assertAst "ENV foo bar" [Env [("foo", "bar")]]
            it "parse quoted value pair" $ assertAst "ENV foo=\"bar\"" [Env [("foo", "bar")]]
            it "parse multiple unquoted pairs" $
                assertAst "ENV foo=bar baz=foo" [Env [("foo", "bar"), ("baz", "foo")]]
            it "parse multiple quoted pairs" $
                assertAst "ENV foo=\"bar\" baz=\"foo\"" [Env [("foo", "bar"), ("baz", "foo")]]
            it "env works before cmd" $
                let dockerfile = "ENV PATH=\"/root\"\nCMD [\"hadolint\",\"-i\"]"
                    ast = [Env [("PATH", "/root")], Cmd ["hadolint", "-i"]]
                in assertAst dockerfile ast
        describe "parse RUN" $
            it "escaped with space before" $
            let dockerfile = unlines ["RUN yum install -y \\ ", "imagemagick \\ ", "mysql"]
            in assertAst dockerfile [Run ["yum", "install", "-y", "imagemagick", "mysql"], EOL, EOL]
        describe "parse CMD" $ do
            it "one line cmd" $ assertAst "CMD true" [Cmd ["true"]]
            it "cmd over several lines" $
                assertAst "CMD true \\\n && true" [Cmd ["true", "&&", "true"], EOL]
            it "quoted command params" $ assertAst "CMD [\"echo\",  \"1\"]" [Cmd ["echo", "1"]]
        describe "parse MAINTAINER" $ do
            it "maintainer of untagged scratch image" $
                assertAst
                    "FROM scratch\nMAINTAINER hudu@mail.com"
                    [From (UntaggedImage "scratch"), Maintainer "hudu@mail.com"]
            it "maintainer with mail" $
                assertAst "MAINTAINER hudu@mail.com" [Maintainer "hudu@mail.com"]
            it "maintainer only mail after from" $
                let maintainerFromProg = "FROM busybox\nMAINTAINER hudu@mail.com"
                    maintainerFromAst = [From (UntaggedImage "busybox"), Maintainer "hudu@mail.com"]
                in assertAst maintainerFromProg maintainerFromAst
        describe "parse # comment " $ do
            it "multiple comments before run" $
                let dockerfile = unlines ["# line 1", "# line 2", "RUN apt-get update"]
                in assertAst dockerfile [Comment " line 1", Comment " line 2", Run ["apt-get", "update"], EOL]
            it "multiple comments after run" $
                let dockerfile = unlines ["RUN apt-get update", "# line 1", "# line 2"]
                in assertAst
                       dockerfile
                       [Run ["apt-get", "update"], Comment " line 1", Comment " line 2", EOL]
        describe "normalize lines" $ do
            it "join escaped lines" $
                let dockerfile = unlines ["ENV foo=bar \\", "baz=foz"]
                    normalizedDockerfile = unlines ["ENV foo=bar  baz=foz", ""]
                in normalizeEscapedLines dockerfile `shouldBe` normalizedDockerfile
            it "join long CMD" $
                let longEscapedCmd =
                        unlines
                            [ "RUN wget https://download.com/${version}.tar.gz -O /tmp/logstash.tar.gz && \\"
                            , "(cd /tmp && tar zxf logstash.tar.gz && mv logstash-${version} /opt/logstash && \\"
                            , "rm logstash.tar.gz) && \\"
                            , "(cd /opt/logstash && \\"
                            , "/opt/logstash/bin/plugin install contrib)"
                            ]
                    longEscapedCmdExpected =
                        concat
                            [ "RUN wget https://download.com/${version}.tar.gz -O /tmp/logstash.tar.gz &&  "
                            , "(cd /tmp && tar zxf logstash.tar.gz && mv logstash-${version} /opt/logstash &&  "
                            , "rm logstash.tar.gz) &&  "
                            , "(cd /opt/logstash &&  "
                            , "/opt/logstash/bin/plugin install contrib)\n"
                            , "\n"
                            , "\n"
                            , "\n"
                            , "\n"
                            ]
                in normalizeEscapedLines longEscapedCmd `shouldBe` longEscapedCmdExpected
        describe "FROM rules" $ do
            it "no untagged" $ ruleCatches noUntagged "FROM debian"
            it "explicit latest" $ ruleCatches noLatestTag "FROM debian:latest"
            it "explicit tagged" $ ruleCatchesNot noLatestTag "FROM debian:jessie"
        describe "no root or sudo rules" $ do
            it "sudo" $ ruleCatches noSudo "RUN sudo apt-get update"
            it "no root" $ ruleCatches noRootUser "USER root"
            it "install sudo" $ ruleCatchesNot noSudo "RUN apt-get install sudo"
            it "sudo chained programs" $
                ruleCatches noSudo "RUN apt-get update && sudo apt-get install"
        describe "invalid CMD rules" $ do
            it "invalid cmd" $ ruleCatches invalidCmd "RUN top"
            it "install ssh" $ ruleCatchesNot invalidCmd "RUN apt-get install ssh"
        describe "apt-get rules" $ do
            it "apt upgrade" $ ruleCatches noUpgrade "RUN apt-get update && apt-get upgrade"
            it "apt-get version pinning" $
                ruleCatches aptGetVersionPinned "RUN apt-get update && apt-get install python"
            it "apt-get no cleanup" $
                ruleCatches aptGetCleanup "RUN apt-get update && apt-get install python"
            it "apt-get cleanup" $
                ruleCatchesNot
                    aptGetCleanup
                    "RUN apt-get update && apt-get install python && rm -rf /var/lib/apt/lists/*"
            it "apt-get pinned chained" $
                let dockerfile =
                        [ "RUN apt-get update \\"
                        , " && apt-get -y --no-install-recommends install nodejs=0.10 \\"
                        , " && rm -rf /var/lib/apt/lists/*"
                        ]
                in ruleCatchesNot aptGetVersionPinned $ unlines dockerfile
            it "apt-get pinned regression" $
                let dockerfile =
                        [ "RUN apt-get update && apt-get install --no-install-recommends -y \\"
                        , "python-demjson=2.2.2* \\"
                        , "wget=1.16.1* \\"
                        , "git=1:2.5.0* \\"
                        , "ruby=1:2.1.*"
                        ]
                in ruleCatchesNot aptGetVersionPinned $ unlines dockerfile
            it "has maintainer named" $
                ruleCatchesNot hasMaintainer "FROM busybox\nMAINTAINER hudu@mail.com"
        describe "EXPOSE rules" $ do
            it "invalid port" $ ruleCatches invalidPort "EXPOSE 80000"
            it "valid port" $ ruleCatchesNot invalidPort "EXPOSE 60000"
        describe "other rules" $ do
            it "use add" $ ruleCatches useAdd "COPY packaged-app.tar /usr/src/app"
            it "use not add" $ ruleCatchesNot useAdd "COPY package.json /usr/src/app"
            it "maintainer address" $ ruleCatches maintainerAddress "MAINTAINER Lukas"
            it "maintainer uri" $
                ruleCatchesNot maintainerAddress "MAINTAINER Lukas <me@lukasmartinelli.ch>"
            it "maintainer uri" $
                ruleCatchesNot maintainerAddress "MAINTAINER John Doe <john.doe@example.net>"
            it "maintainer mail" $
                ruleCatchesNot maintainerAddress "MAINTAINER http://lukasmartinelli.ch"
            it "pip requirements" $
                ruleCatchesNot pipVersionPinned "RUN pip install -r requirements.txt"
            it "pip version not pinned" $
                ruleCatches pipVersionPinned "RUN pip install MySQL_python"
            it "pip version pinned" $
                ruleCatchesNot pipVersionPinned "RUN pip install MySQL_python==1.2.2"
            it "apt-get auto yes" $ ruleCatches aptGetYes "RUN apt-get install python"
            it "apt-get yes shortflag" $ ruleCatchesNot aptGetYes "RUN apt-get install -yq python"
            it "apt-get yes different pos" $
                ruleCatchesNot aptGetYes "RUN apt-get install -y python"
            it "apt-get with auto yes" $ ruleCatchesNot aptGetYes "RUN apt-get -y install python"
            it "apt-get with auto expanded yes" $
                ruleCatchesNot aptGetYes "RUN apt-get --yes install python"
            it "apt-get install recommends" $
                ruleCatchesNot
                    aptGetNoRecommends
                    "RUN apt-get install --no-install-recommends python"
            it "apt-get no install recommends" $
                ruleCatches aptGetNoRecommends "RUN apt-get install python"
            it "apt-get no install recommends" $
                ruleCatches aptGetNoRecommends "RUN apt-get -y install python"
            it "apt-get version" $
                ruleCatchesNot aptGetVersionPinned "RUN apt-get install -y python=1.2.2"
            it "apt-get pinned" $
                ruleCatchesNot
                    aptGetVersionPinned
                    "RUN apt-get -y --no-install-recommends install nodejs=0.10"
            it "has maintainer" $ ruleCatchesNot hasMaintainer "FROM debian\nMAINTAINER Lukas"
            it "has maintainer first" $ ruleCatchesNot hasMaintainer "MAINTAINER Lukas\nFROM DEBIAN"
            it "has no maintainer" $ ruleCatches hasMaintainer "FROM debian"
            it "using add" $ ruleCatches copyInsteadAdd "ADD file /usr/src/app/"
            it "add is ok for archive" $ ruleCatchesNot copyInsteadAdd "ADD file.tar /usr/src/app/"
            it "add is ok for url" $
                ruleCatchesNot copyInsteadAdd "ADD http://file.com /usr/src/app/"
            it "many cmds" $ ruleCatches multipleCmds "CMD /bin/true\nCMD /bin/true"
            it "single cmd" $ ruleCatchesNot multipleCmds "CMD /bin/true"
            it "no cmd" $ ruleCatchesNot multipleEntrypoints "FROM busybox"
            it "many entries" $
                ruleCatches multipleEntrypoints "ENTRYPOINT /bin/true\nENTRYPOINT /bin/true"
            it "single entry" $ ruleCatchesNot multipleEntrypoints "ENTRYPOINT /bin/true"
            it "no entry" $ ruleCatchesNot multipleEntrypoints "FROM busybox"
            it "workdir variable" $ ruleCatchesNot absoluteWorkdir "WORKDIR ${work}"
            it "scratch" $ ruleCatchesNot noUntagged "FROM scratch"
        describe "expose" $ do
            it "should handle number ports" $ do
                let content = "EXPOSE 8080"
                parse expose "" content `shouldBe` Right (Expose (Ports [8080]))
        describe "syntax" $ do
            it "should handle lowercase instructions (#7 - https://github.com/beijaflor-io/haskell-language-dockerfile/issues/7)" $ do
                let content = "from ubuntu"
                parse dockerfile "" content `shouldBe` Right [InstructionPos (From (UntaggedImage "ubuntu")) "" 1]

assertAst s ast =
    case parseString (s ++ "\n") of
        Left err -> assertFailure $ show err
        Right dockerfile -> assertEqual "ASTs are not equal" ast $ map instruction dockerfile

assertChecks rule s f =
    case parseString (s ++ "\n") of
        Left err -> assertFailure $ show err
        Right dockerfile -> f $ analyze [rule] dockerfile

-- Assert a failed check exists for rule
ruleCatches :: Rule -> String -> Assertion
ruleCatches rule s = assertChecks rule s f
  where
    f checks = assertEqual "No check for rule found" 1 $ length checks

ruleCatchesNot :: Rule -> String -> Assertion
ruleCatchesNot rule s = assertChecks rule s f
  where
    f checks = assertEqual "Found check of rule" 0 $ length checks
