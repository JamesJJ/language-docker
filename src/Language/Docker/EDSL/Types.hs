{-# LANGUAGE DeriveFunctor #-}

module Language.Docker.EDSL.Types where

import Data.ByteString.Char8 (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.String
import qualified Language.Docker.Syntax as Syntax

data EBaseImage
    = EUntaggedImage Syntax.Image
                     (Maybe Syntax.ImageAlias)
    | ETaggedImage Syntax.Image
                   String
                   (Maybe Syntax.ImageAlias)
    | EDigestedImage Syntax.Image
                     ByteString
                     (Maybe Syntax.ImageAlias)
    deriving (Show, Eq, Ord)

instance IsString EBaseImage where
    fromString = flip EUntaggedImage Nothing . fromString

data EInstruction next
    = From EBaseImage
           next
    | AddArgs (NonEmpty Syntax.SourcePath)
              Syntax.TargetPath
              Syntax.Chown
              next
    | User String
           next
    | Label Syntax.Pairs
            next
    | StopSignal String
                 next
    | CopyArgs (NonEmpty Syntax.SourcePath)
               Syntax.TargetPath
               Syntax.Chown
               Syntax.CopySource
               next
    | RunArgs Syntax.Arguments
              next
    | CmdArgs Syntax.Arguments
              next
    | Shell Syntax.Arguments
            next
    | Workdir Syntax.Directory
              next
    | Expose Syntax.Ports
             next
    | Volume String
             next
    | EntrypointArgs Syntax.Arguments
                     next
    | Maintainer String
                 next
    | Env Syntax.Pairs
          next
    | Arg String
          (Maybe String)
          next
    | Comment String
              next
    | Healthcheck Syntax.Check
                  next
    | OnBuildRaw Syntax.Instruction
                 next
    | Embed [Syntax.InstructionPos]
            next
    deriving (Functor)
