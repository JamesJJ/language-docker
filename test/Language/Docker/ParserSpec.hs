{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedLists #-}
module Language.Docker.ParserSpec where

import Language.Docker.Normalize
import Language.Docker.Parser
import Language.Docker.Syntax


import Test.HUnit hiding (Label)
import Test.Hspec
import Text.Parsec

spec :: Spec
spec = do
        describe "parse ARG" $ do
            it "no default" $
                assertAst "ARG FOO" [Arg "FOO" Nothing]
            it "with default" $
                assertAst "ARG FOO=bar" [Arg "FOO" (Just "bar")]

        describe "parse FROM" $ do
            it "parse untagged image" $
                assertAst "FROM busybox" [From (UntaggedImage "busybox" Nothing)]
            it "parse tagged image" $
                assertAst
                    "FROM busybox:5.12-dev"
                    [From (TaggedImage "busybox" "5.12-dev" Nothing)]
            it "parse digested image" $
                assertAst
                    "FROM ubuntu@sha256:0ef2e08ed3fab"
                    [From (DigestedImage "ubuntu" "sha256:0ef2e08ed3fab" Nothing)]

        describe "parse aliased FROM" $ do
            it "parse untagged image" $
                assertAst "FROM busybox as foo" [From (UntaggedImage "busybox" (Just $ ImageAlias "foo"))]
            it "parse tagged image" $
                assertAst "FROM busybox:5.12-dev AS foo-bar" [From (TaggedImage "busybox" "5.12-dev" (Just $ ImageAlias "foo-bar"))]
            it "parse diggested image" $
                assertAst "FROM ubuntu@sha256:0ef2e08ed3fab AS foo" [From (DigestedImage "ubuntu" "sha256:0ef2e08ed3fab" (Just $ ImageAlias "foo"))]

        describe "parse FROM with registry" $ do
            it "registry without port" $
                assertAst "FROM foo.com/node" [From (UntaggedImage (Image (Just "foo.com") "node") Nothing)]
            it "parse with port and tag" $
                assertAst
                "FROM myregistry.com:5000/imagename:5.12-dev"
                [From (TaggedImage (Image (Just "myregistry.com:5000") "imagename") "5.12-dev" Nothing)]

        describe "parse LABEL" $ do
            it "parse label" $ assertAst "LABEL foo=bar" [Label[("foo", "bar")]]
            it "parse space separated label" $ assertAst "LABEL foo bar baz" [Label[("foo", "bar baz")]]
            it "parse quoted labels" $ assertAst "LABEL \"foo bar\"=baz" [Label[("foo bar", "baz")]]
            it "parses multiline labels" $
                let dockerfile = unlines [ "LABEL foo=bar \\", "hobo=mobo"]
                    ast = [ Label [("foo", "bar"), ("hobo", "mobo")] ]
                in assertAst dockerfile ast

        describe "parse ENV" $ do
            it "parses unquoted pair" $ assertAst "ENV foo=bar" [Env [("foo", "bar")]]
            it "parse with space between key and value" $
                assertAst "ENV foo bar" [Env [("foo", "bar")]]
            it "parse with more then one (white)space between key and value" $
                let dockerfile = "ENV          NODE_VERSION  \t   v5.7.1"
                in assertAst dockerfile [Env[("NODE_VERSION",    "v5.7.1")]]
            it "parse quoted value pair" $ assertAst "ENV foo=\"bar\"" [Env [("foo", "bar")]]
            it "parse multiple unquoted pairs" $
                assertAst "ENV foo=bar baz=foo" [Env [("foo", "bar"), ("baz", "foo")]]
            it "parse multiple quoted pairs" $
                assertAst "ENV foo=\"bar\" baz=\"foo\"" [Env [("foo", "bar"), ("baz", "foo")]]
            it "env works before cmd" $
                let dockerfile = "ENV PATH=\"/root\"\nCMD [\"hadolint\",\"-i\"]"
                    ast = [Env [("PATH", "/root")], Cmd ["hadolint", "-i"]]
                in assertAst dockerfile ast
            it "parse with two spaces between" $
                let dockerfile = "ENV NODE_VERSION=v5.7.1  DEBIAN_FRONTEND=noninteractive"
                in assertAst dockerfile [Env[("NODE_VERSION", "v5.7.1"), ("DEBIAN_FRONTEND", "noninteractive")]]
            it "have envs on multiple lines" $
                let dockerfile = unlines [ "FROM busybox"
                                 , "ENV NODE_VERSION=v5.7.1 \\"
                                 , "DEBIAN_FRONTEND=noninteractive"
                                 ]
                    ast = [ From (UntaggedImage "busybox" Nothing)
                          , Env[("NODE_VERSION", "v5.7.1"), ("DEBIAN_FRONTEND", "noninteractive")]
                          ]
                in assertAst dockerfile ast
            it "parses long env over multiple lines" $
                let dockerfile = unlines [ "ENV LD_LIBRARY_PATH=\"/usr/lib/\" \\"
                                         , "APACHE_RUN_USER=\"www-data\" APACHE_RUN_GROUP=\"www-data\""]
                    ast = [Env [("LD_LIBRARY_PATH", "/usr/lib/")
                               ,("APACHE_RUN_USER", "www-data")
                               ,("APACHE_RUN_GROUP", "www-data")
                               ]
                          ]
                in assertAst dockerfile ast
            it "parse single var list" $
                assertAst "ENV foo val1 val2 val3 val4" [Env [("foo", "val1 val2 val3 val4")]]
            it "parses many env lines with an equal sign in the value" $
                let dockerfile = unlines [ "ENV TOMCAT_VERSION 9.0.2"
                                         , "ENV TOMCAT_URL foo.com?q=1"
                                         ]
                    ast = [ Env [("TOMCAT_VERSION", "9.0.2")]
                          , Env [("TOMCAT_URL", "foo.com?q=1")]
                          ]
                in assertAst dockerfile ast
            it "parses many env lines in mixed style" $
                let dockerfile = unlines [ "ENV myName=\"John Doe\" myDog=Rex\\ The\\ Dog \\"
                                         , "    myCat=fluffy"
                                         ]
                    ast = [ Env [("myName", "John Doe")
                                ,("myDog", "Rex The Dog")
                                ,("myCat", "fluffy")
                                ]
                          ]
                in assertAst dockerfile ast
            it "parses many env with backslashes" $
                let dockerfile = unlines [ "ENV JAVA_HOME=C:\\\\jdk1.8.0_112"
                                         ]
                    ast = [ Env [("JAVA_HOME", "C:\\\\jdk1.8.0_112")]
                          ]
                in assertAst dockerfile ast

        describe "parse RUN" $ do
            it "escaped with space before" $
                let dockerfile = unlines ["RUN yum install -y \\ ", "imagemagick \\ ", "mysql"]
                in assertAst dockerfile [Run ["yum", "install", "-y", "imagemagick", "mysql"]]

            it "does not choke on unmatched brackets" $
                let dockerfile = unlines ["RUN [foo"]
                in assertAst dockerfile [Run ["[foo"]]

        describe "parse CMD" $ do
            it "one line cmd" $ assertAst "CMD true" [Cmd ["true"]]
            it "cmd over several lines" $
                assertAst "CMD true \\\n && true" [Cmd ["true", "&&", "true"]]
            it "quoted command params" $ assertAst "CMD [\"echo\",  \"1\"]" [Cmd ["echo", "1"]]

        describe "parse SHELL" $ do
            it "quoted shell params" $
                assertAst "SHELL [\"/bin/bash\",  \"-c\"]" [Shell ["/bin/bash", "-c"]]

        describe "parse HEALTHCHECK" $ do
            it "parse healthcheck with interval" $
              assertAst
                "HEALTHCHECK --interval=5m \\\nCMD curl -f http://localhost/"
                [Healthcheck $
                    Check $
                      CheckArgs "curl -f http://localhost/" (Just 300) Nothing Nothing Nothing
                ]

            it "parse healthcheck with retries" $
              assertAst
                "HEALTHCHECK --retries=10 CMD curl -f http://localhost/"
                [Healthcheck $
                    Check $
                      CheckArgs "curl -f http://localhost/" Nothing Nothing Nothing (Just $ Retries 10)
                ]

            it "parse healthcheck with timeout" $
              assertAst
                "HEALTHCHECK --timeout=10s CMD curl -f http://localhost/"
                [Healthcheck $
                    Check $
                      CheckArgs "curl -f http://localhost/" Nothing (Just 10) Nothing Nothing
                ]

            it "parse healthcheck with start-period" $
              assertAst
                "HEALTHCHECK --start-period=2m CMD curl -f http://localhost/"
                [Healthcheck $
                    Check $
                      CheckArgs "curl -f http://localhost/" Nothing Nothing (Just 120) Nothing
                ]

            it "parse healthcheck with all flags" $
              assertAst
                "HEALTHCHECK --start-period=2s --timeout=1m --retries=3 --interval=5s    CMD curl -f http://localhost/"
                [Healthcheck $
                    Check $
                      CheckArgs
                        "curl -f http://localhost/"
                        (Just 5)
                        (Just 60)
                        (Just 2)
                        (Just $ Retries 3)
                ]

            it "parse healthcheck with no flags" $
              assertAst
                "HEALTHCHECK CMD curl -f http://localhost/"
                [Healthcheck $
                    Check $
                      CheckArgs "curl -f http://localhost/" Nothing Nothing Nothing Nothing
                ]

        describe "parse MAINTAINER" $ do
            it "maintainer of untagged scratch image" $
                assertAst
                    "FROM scratch\nMAINTAINER hudu@mail.com"
                    [From (UntaggedImage "scratch" Nothing), Maintainer "hudu@mail.com"]
            it "maintainer with mail" $
                assertAst "MAINTAINER hudu@mail.com" [Maintainer "hudu@mail.com"]
            it "maintainer only mail after from" $
                let maintainerFromProg = "FROM busybox\nMAINTAINER hudu@mail.com"
                    maintainerFromAst = [From (UntaggedImage "busybox" Nothing), Maintainer "hudu@mail.com"]
                in assertAst maintainerFromProg maintainerFromAst
        describe "parse # comment " $ do
            it "multiple comments before run" $
                let dockerfile = unlines ["# line 1", "# line 2", "RUN apt-get update"]
                in assertAst dockerfile [Comment " line 1", Comment " line 2", Run ["apt-get", "update"]]
            it "multiple comments after run" $
                let dockerfile = unlines ["RUN apt-get update", "# line 1", "# line 2"]
                in assertAst
                       dockerfile
                       [Run ["apt-get", "update"], Comment " line 1", Comment " line 2"]

            it "empty comment" $
                let dockerfile = unlines ["#", "# Hello"]
                in assertAst dockerfile [Comment "", Comment " Hello"]
        describe "normalize lines" $ do
            it "join multiple ENV" $
                let dockerfile = unlines [ "FROM busybox"
                                 , "ENV NODE_VERSION=v5.7.1 \\"
                                 , "DEBIAN_FRONTEND=noninteractive"
                                 ]
                    normalizedDockerfile = unlines [ "FROM busybox"
                                                   , "ENV NODE_VERSION=v5.7.1  DEBIAN_FRONTEND=noninteractive\n"
                                                   ]
                in normalizeEscapedLines dockerfile `shouldBe` normalizedDockerfile
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
                            ([ "RUN wget https://download.com/${version}.tar.gz -O /tmp/logstash.tar.gz &&  "
                            , "(cd /tmp && tar zxf logstash.tar.gz && mv logstash-${version} /opt/logstash &&  "
                            , "rm logstash.tar.gz) &&  "
                            , "(cd /opt/logstash &&  "
                            , "/opt/logstash/bin/plugin install contrib)\n"
                            , "\n"
                            , "\n"
                            , "\n"
                            , "\n"
                            ] :: [String])
                in normalizeEscapedLines longEscapedCmd `shouldBe` longEscapedCmdExpected
        describe "expose" $ do
            it "should handle number ports" $ do
                let content = "EXPOSE 8080"
                parse expose "" content `shouldBe` Right (Expose (Ports [Port 8080 TCP]))
            it "should handle many number ports" $ do
                let content = "EXPOSE 8080 8081"
                parse expose "" content `shouldBe` Right (Expose (Ports [Port 8080 TCP, Port 8081 TCP]))
            it "should handle ports with protocol" $ do
                let content = "EXPOSE 8080/TCP 8081/UDP"
                parse expose "" content `shouldBe` Right (Expose (Ports [Port 8080 TCP, Port 8081 UDP]))
            it "should handle ports with protocol and variables" $ do
                let content = "EXPOSE $PORT 8080 8081/UDP"
                parse expose "" content `shouldBe` Right (Expose (Ports [PortStr "$PORT", Port 8080 TCP, Port 8081 UDP]))
            it "should handle port ranges" $ do
                let content = "EXPOSE 80 81 8080-8085"
                parse expose "" content `shouldBe` Right (Expose (Ports [Port 80 TCP, Port 81 TCP, PortRange 8080 8085]))

        describe "syntax" $ do
            it "should handle lowercase instructions (#7 - https://github.com/beijaflor-io/haskell-language-dockerfile/issues/7)" $ do
                let content = "from ubuntu"
                parse dockerfile "" content `shouldBe` Right [InstructionPos (From (UntaggedImage "ubuntu" Nothing)) "" 1]

        describe "ADD" $ do
            it "simple ADD" $
                let file = unlines ["ADD . /app", "ADD http://foo.bar/baz ."]
                in assertAst file [ Add $ AddArgs [SourcePath "."] (TargetPath "/app") NoChown
                                  , Add $ AddArgs [SourcePath "http://foo.bar/baz"] (TargetPath ".") NoChown
                                  ]
            it "multifiles ADD" $
                let file = unlines ["ADD foo bar baz /app"]
                in assertAst file [ Add $ AddArgs (fmap SourcePath ["foo", "bar", "baz"]) (TargetPath "/app") NoChown
                                  ]

            it "list of quoted files" $
                let file = unlines ["ADD [\"foo\", \"bar\", \"baz\", \"/app\"]"]
                in assertAst file [ Add $ AddArgs (fmap SourcePath ["foo", "bar", "baz"]) (TargetPath "/app") NoChown
                                  ]

            it "with chown flag" $
                let file = unlines ["ADD --chown=root:root foo bar"]
                in assertAst file [ Add $ AddArgs (fmap SourcePath ["foo"]) (TargetPath "bar") (Chown "root:root")
                                  ]

            it "list of quoted files and chown" $
                let file = unlines ["ADD --chown=user:group [\"foo\", \"bar\", \"baz\", \"/app\"]"]
                in assertAst file [ Add $ AddArgs (fmap SourcePath ["foo", "bar", "baz"]) (TargetPath "/app") (Chown "user:group")
                                  ]
        describe "COPY" $ do
            it "simple COPY" $
                let file = unlines ["COPY . /app", "COPY baz /some/long/path"]
                in assertAst file [ Copy $ CopyArgs [SourcePath "."] (TargetPath "/app") NoChown NoSource
                                  , Copy $ CopyArgs [SourcePath "baz"] (TargetPath "/some/long/path") NoChown NoSource
                                  ]
            it "multifiles COPY" $
                let file = unlines ["COPY foo bar baz /app"]
                in assertAst file [ Copy $ CopyArgs (fmap SourcePath ["foo", "bar", "baz"]) (TargetPath "/app") NoChown NoSource
                                  ]

            it "list of quoted files" $
                let file = unlines ["COPY [\"foo\", \"bar\", \"baz\", \"/app\"]"]
                in assertAst file [ Copy $ CopyArgs (fmap SourcePath ["foo", "bar", "baz"]) (TargetPath "/app") NoChown NoSource
                                  ]

            it "with chown flag" $
                let file = unlines ["COPY --chown=user:group foo bar"]
                in assertAst file [ Copy $ CopyArgs (fmap SourcePath ["foo"]) (TargetPath "bar") (Chown "user:group") NoSource
                                  ]

            it "with from flag" $
                let file = unlines ["COPY --from=node foo bar"]
                in assertAst file [ Copy $ CopyArgs (fmap SourcePath ["foo"]) (TargetPath "bar") NoChown (CopySource "node")
                                  ]
            it "with both flags" $
                let file = unlines ["COPY --from=node --chown=user:group foo bar"]
                in assertAst file [ Copy $ CopyArgs (fmap SourcePath ["foo"]) (TargetPath "bar") (Chown "user:group") (CopySource "node")
                                  ]
            it "with both flags in different order" $
                let file = unlines ["COPY --chown=user:group --from=node foo bar"]
                in assertAst file [ Copy $ CopyArgs (fmap SourcePath ["foo"]) (TargetPath "bar") (Chown "user:group") (CopySource "node")
                                  ]
assertAst s ast =
    case parseString (s ++ "\n") of
        Left err -> assertFailure $ show err
        Right dockerfile -> assertEqual "ASTs are not equal" ast $ map instruction dockerfile
