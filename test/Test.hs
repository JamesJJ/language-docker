import           Data.List                      (find)
import           Data.Maybe                     (fromMaybe, isJust)

import           Language.Dockerfile.Normalize
import           Language.Dockerfile.Parser
import           Language.Dockerfile.Rules
import           Language.Dockerfile.Syntax

import           Test.Framework
import           Test.Framework.Providers.HUnit
import           Test.HUnit

assertAst s ast = case parseString (s ++ "\n") of
    Left err          -> assertFailure $ show err
    Right dockerfile  -> assertEqual "ASTs are not equal" ast $ map instruction dockerfile

assertChecks rule s f = case parseString (s ++ "\n") of
    Left err -> assertFailure $ show err
    Right dockerfile  -> f $ analyze [rule] dockerfile

-- Assert a failed check exists for rule
ruleCatches :: Rule -> String -> Assertion
ruleCatches rule s = assertChecks rule s f
    where f checks = assertEqual "No check for rule found" 1 $ length checks

ruleCatchesNot :: Rule -> String -> Assertion
ruleCatchesNot rule s = assertChecks rule s f
    where f checks = assertEqual "Found check of rule" 0 $ length checks

normalizeTests = [ "join escaped lines" ~: assertEqual "Lines are not joined" expected $ normalizeEscapedLines dockerfile
                 , "join long cmd" ~: assertEqual "Lines are not joined" longEscapedCmdExpected $ normalizeEscapedLines longEscapedCmd
                 ]
    where expected = unlines ["ENV foo=bar  baz=foz", ""]
          dockerfile = unlines ["ENV foo=bar \\", "baz=foz"]


longEscapedCmd = unlines
    [ "RUN wget https://download.com/${version}.tar.gz -O /tmp/logstash.tar.gz && \\"
    , "(cd /tmp && tar zxf logstash.tar.gz && mv logstash-${version} /opt/logstash && \\"
    , "rm logstash.tar.gz) && \\"
    , "(cd /opt/logstash && \\"
    ,  "/opt/logstash/bin/plugin install contrib)"
    ]

longEscapedCmdExpected = concat
    [ "RUN wget https://download.com/${version}.tar.gz -O /tmp/logstash.tar.gz &&  "
    , "(cd /tmp && tar zxf logstash.tar.gz && mv logstash-${version} /opt/logstash &&  "
    , "rm logstash.tar.gz) &&  "
    , "(cd /opt/logstash &&  "
    ,  "/opt/logstash/bin/plugin install contrib)\n"
    , "\n"
    , "\n"
    , "\n"
    , "\n"
    ]


astTests =
    [ "from untagged" ~: assertAst "FROM busybox" [From (UntaggedImage "busybox")]
    , "env pair" ~: assertAst "ENV foo=bar" [Env [("foo", "bar")]]
    , "env space pair" ~: assertAst "ENV foo bar" [Env [("foo", "bar")] ]
    , "env quoted pair" ~: assertAst "ENV foo=\"bar\"" [Env [("foo", "bar")]]
    , "env multi raw pair" ~: assertAst "ENV foo=bar baz=foo" [Env [("foo", "bar"), ("baz", "foo")]]
    , "env multi quoted pair" ~: assertAst "ENV foo=\"bar\" baz=\"foo\"" [Env [("foo", "bar"), ("baz", "foo")]]
    , "one line cmd" ~: assertAst "CMD true" [Cmd ["true"]]
    , "multiline cmd" ~: assertAst "CMD true \\\n && true" [Cmd ["true", "&&", "true"], EOL]
    , "maintainer " ~: assertAst "MAINTAINER hudu@mail.com" [Maintainer "hudu@mail.com"]
    , "maintainer from" ~: assertAst maintainerFromProg maintainerFromAst
    , "quoted exec" ~: assertAst "CMD [\"echo\",  \"1\"]" [Cmd ["echo", "1"]]
    , "env works with cmd" ~: assertAst envWorksCmdProg envWorksCmdAst
    , "multicomments first" ~: assertAst multiCommentsProg1 [Comment " line 1", Comment " line 2", Run ["apt-get", "update"], EOL]
    , "multicomments after" ~: assertAst multiCommentsProg2 [Run ["apt-get", "update"], Comment " line 1", Comment " line 2", EOL]
    , "escape with space" ~: assertAst escapedWithSpaceProgram [Run ["yum", "install", "-y", "imagemagick", "mysql"], EOL, EOL]
    , "scratch and maintainer" ~: assertAst "FROM scratch\nMAINTAINER hudu@mail.com" [From (UntaggedImage "scratch"), Maintainer "hudu@mail.com"]
    ] where
        maintainerFromProg = "FROM busybox\nMAINTAINER hudu@mail.com"
        maintainerFromAst = [ From (UntaggedImage "busybox")
                            , Maintainer "hudu@mail.com"
                            ]
        envWorksCmdProg = "ENV PATH=\"/root\"\nCMD [\"hadolint\",\"-i\"]"
        envWorksCmdAst = [ Env [("PATH", "/root")]
                         , Cmd ["hadolint", "-i"]
                         ]
        multiCommentsProg1 = unlines [ "# line 1"
                                     , "# line 2"
                                     , "RUN apt-get update"
                                     ]
        multiCommentsProg2 = unlines [ "RUN apt-get update"
                                     , "# line 1"
                                     , "# line 2"
                                     ]
        escapedWithSpaceProgram = unlines [ "RUN yum install -y \\ "
                                          , "imagemagick \\ "
                                          , "mysql"
                                          ]

ruleTests =
    [ "untagged" ~: ruleCatches noUntagged "FROM debian"
    , "explicit latest" ~: ruleCatches noLatestTag "FROM debian:latest"
    , "explicit tagged" ~: ruleCatchesNot noLatestTag "FROM debian:jessie"
    , "sudo" ~: ruleCatches noSudo "RUN sudo apt-get update"
    , "no root" ~: ruleCatches noRootUser "USER root"
    , "install sudo" ~: ruleCatchesNot noSudo "RUN apt-get install sudo"
    , "sudo chained programs" ~: ruleCatches noSudo "RUN apt-get update && sudo apt-get install"
    , "invalid cmd" ~: ruleCatches invalidCmd "RUN top"
    , "install ssh" ~: ruleCatchesNot invalidCmd "RUN apt-get install ssh"
    , "apt upgrade" ~: ruleCatches noUpgrade "RUN apt-get update && apt-get upgrade"
    , "apt-get version pinning" ~: ruleCatches aptGetVersionPinned "RUN apt-get update && apt-get install python"
    , "apt-get no cleanup" ~: ruleCatches aptGetCleanup "RUN apt-get update && apt-get install python"
    , "apt-get cleanup" ~: ruleCatchesNot aptGetCleanup "RUN apt-get update && apt-get install python && rm -rf /var/lib/apt/lists/*"
    , "use add" ~: ruleCatches useAdd "COPY packaged-app.tar /usr/src/app"
    , "use not add" ~: ruleCatchesNot useAdd "COPY package.json /usr/src/app"
    , "invalid port" ~: ruleCatches invalidPort "EXPOSE 80000"
    , "valid port" ~: ruleCatchesNot invalidPort "EXPOSE 60000"
    , "maintainer address" ~: ruleCatches maintainerAddress "MAINTAINER Lukas"
    , "maintainer uri" ~: ruleCatchesNot maintainerAddress "MAINTAINER Lukas <me@lukasmartinelli.ch>"
    , "maintainer uri" ~: ruleCatchesNot maintainerAddress "MAINTAINER John Doe <john.doe@example.net>"
    , "maintainer mail" ~: ruleCatchesNot maintainerAddress "MAINTAINER http://lukasmartinelli.ch"
    , "pip requirements" ~: ruleCatchesNot pipVersionPinned "RUN pip install -r requirements.txt"
    , "pip version not pinned" ~: ruleCatches pipVersionPinned "RUN pip install MySQL_python"
    , "pip version pinned" ~: ruleCatchesNot pipVersionPinned "RUN pip install MySQL_python==1.2.2"
    , "apt-get auto yes" ~: ruleCatches aptGetYes "RUN apt-get install python"
    , "apt-get yes shortflag" ~: ruleCatchesNot aptGetYes "RUN apt-get install -yq python"
    , "apt-get yes different pos" ~: ruleCatchesNot aptGetYes "RUN apt-get install -y python"
    , "apt-get with auto yes" ~: ruleCatchesNot aptGetYes "RUN apt-get -y install python"
    , "apt-get with auto expanded yes" ~: ruleCatchesNot aptGetYes "RUN apt-get --yes install python"
    , "apt-get install recommends" ~: ruleCatchesNot aptGetNoRecommends "RUN apt-get install --no-install-recommends python"
    , "apt-get no install recommends" ~: ruleCatches aptGetNoRecommends "RUN apt-get install python"
    , "apt-get no install recommends" ~: ruleCatches aptGetNoRecommends "RUN apt-get -y install python"
    , "apt-get version" ~: ruleCatchesNot aptGetVersionPinned "RUN apt-get install -y python=1.2.2"
    , "apt-get pinned" ~: ruleCatchesNot aptGetVersionPinned "RUN apt-get -y --no-install-recommends install nodejs=0.10"
    , "apt-get pinned chained" ~: ruleCatchesNot aptGetVersionPinned $ unlines aptGetPinnedChainedProgram
    , "apt-get pinned regression" ~: ruleCatchesNot aptGetVersionPinned $ unlines aptGetPinnedRegressionProgram
    , "has maintainer named" ~: ruleCatchesNot hasMaintainer "FROM busybox\nMAINTAINER hudu@mail.com"
    , "has maintainer" ~: ruleCatchesNot hasMaintainer "FROM debian\nMAINTAINER Lukas"
    , "has maintainer first" ~: ruleCatchesNot hasMaintainer "MAINTAINER Lukas\nFROM DEBIAN"
    , "has no maintainer" ~: ruleCatches hasMaintainer "FROM debian"
    , "using add" ~: ruleCatches copyInsteadAdd "ADD file /usr/src/app/"
    , "add is ok for archive" ~: ruleCatchesNot copyInsteadAdd "ADD file.tar /usr/src/app/"
    , "add is ok for url" ~: ruleCatchesNot copyInsteadAdd "ADD http://file.com /usr/src/app/"
    , "many cmds" ~: ruleCatches multipleCmds "CMD /bin/true\nCMD /bin/true"
    , "single cmd" ~: ruleCatchesNot multipleCmds "CMD /bin/true"
    , "no cmd" ~: ruleCatchesNot multipleEntrypoints "FROM busybox"
    , "many entries" ~: ruleCatches multipleEntrypoints "ENTRYPOINT /bin/true\nENTRYPOINT /bin/true"
    , "single entry" ~: ruleCatchesNot multipleEntrypoints "ENTRYPOINT /bin/true"
    , "no entry" ~: ruleCatchesNot multipleEntrypoints "FROM busybox"
    , "workdir variable" ~: ruleCatchesNot absoluteWorkdir "WORKDIR ${work}"
    , "scratch" ~: ruleCatchesNot noUntagged "FROM scratch"
    ] where
    aptGetPinnedChainedProgram =
        [ "RUN apt-get update \\"
        , " && apt-get -y --no-install-recommends install nodejs=0.10 \\"
        , " && rm -rf /var/lib/apt/lists/*"
        ]
    aptGetPinnedRegressionProgram =
        [ "RUN apt-get update && apt-get install --no-install-recommends -y \\"
        , "python-demjson=2.2.2* \\"
        , "wget=1.16.1* \\"
        , "git=1:2.5.0* \\"
        , "ruby=1:2.1.*"
        ]

tests = test $ ruleTests ++ astTests ++ normalizeTests
main = defaultMain $ hUnitTestToTests tests
