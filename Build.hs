{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
import Data.List
import System.Exit
import Control.Concurrent.MVar
import Development.Shake
import Development.Shake.Util
import Development.Shake.Config ()
import Development.Shake.Classes
import Development.Shake.FilePath

newtype OcamlOrdOracle = OcamlOrdOracle String
                       deriving (Show,Typeable,Eq,Hashable,Binary,NFData)
newtype OcamlCmdLineOracle = OcamlCmdLineOracle String
                           deriving (Show,Typeable,Eq,Hashable,Binary,NFData)
newtype CCmdLineOracle = CCmdLineOracle String
                       deriving (Show,Typeable,Eq,Hashable,Binary,NFData)
newtype GitDescribeOracle = GitDescribeOracle ()
                          deriving (Show,Typeable,Eq,Hashable,Binary,NFData)
data CM = CMO | CMI

outdir = "build"
mudir = "/home/malc/x/rcs/git/mupdf"
inOutDir s = outdir </> s

ocamlc = "ocamlc.opt"
ocamldep = "ocamldep.opt"
ocamlflags = "-warn-error +a -w +a -g -safe-string"
ocamlflagstbl = [("main.cmo", ("-I lablGL", "sed -f pp.sed"))
                ,("config.cmo", ("-I lablGL", ""))
                ]
cflags = "-Wall -Werror -D_GNU_SOURCE -O\
         \ -g -std=c99 -pedantic-errors\
         \ -Wunused-parameter -Wsign-compare -Wshadow"
cflagstbl =
  [("link.o"
   ,"-I " ++ mudir ++ "/include -I "
    ++ mudir ++ "/thirdparty/freetype/include -Wextra")
  ]
cclib = "-lGL -lX11 -lmupdf -lz -lfreetype -ljpeg\
        \ -ljbig2dec -lopenjpeg -lmujs\
        \ -lpthread -L" ++ mudir ++ "/build/native -lcrypto"

getincludes :: [String] -> [String]
getincludes [] = []
getincludes ("-I":arg:tl) = arg : getincludes tl
getincludes (_:tl) = getincludes tl

isabsinc :: String -> Bool
isabsinc [] = False
isabsinc (hd:_) = hd == '+' || hd == '/'

fixincludes [] = []
fixincludes ("-I":d:tl)
  | isabsinc d = "-I":d:fixincludes tl
  | otherwise = "-I":inOutDir d:fixincludes tl
fixincludes (e:tl) = e:fixincludes tl

ocamlKey key | "lablGL/" `isPrefixOf` key = (ocamlc, "-I lablGL", [])
             | otherwise = case lookup key ocamlflagstbl of
               Nothing -> (ocamlc, ocamlflags, [])
               Just (f, []) -> (ocamlc, ocamlflags ++ " " ++ f, [])
               Just (f, pp) -> (ocamlc, ocamlflags ++ " " ++ f, ["-pp", pp])

cKey key | "lablGL/" `isPrefixOf` key = "-Wno-pointer-sign -O2"
         | otherwise = case lookup key cflagstbl of
           Nothing -> cflags
           Just f -> f ++ " " ++ cflags

fixppfile :: String -> [String] -> [String]
fixppfile s ("File":_:tl) = ("File \"" ++ s ++ "\","):tl
fixppfile _ l = l

fixpp :: String -> String -> String
fixpp r s = unlines [unwords $ fixppfile r $ words x | x <- lines s]

ppppe ExitSuccess _ _ = return ()
ppppe _ src emsg = error $ fixpp src emsg

cm' t oracle =
  target `op` \out -> do
    let key = dropDirectory1 out
    let src' = key -<.> suffix
    let src = if src' == "help.ml" then inOutDir src' else src'
    need [src]
    (comp, flags, ppflags) <- oracle $ OcamlCmdLineOracle key
    let flagl = words flags
    need [out ++ "_dep"]
    let fixedflags = fixincludes flagl
    (Stderr emsg2, Exit ex2) <-
      cmd comp "-c -I" outdir fixedflags "-o" out ppflags src
    ppppe ex2 src emsg2
    return ()
  where (target, suffix, op) = case t of
          CMO -> ("//*.cmo", ".ml", (%>))
          CMI -> ("//*.cmi", ".mli", (%>))

cm'dep t oracle ordoracle =
  target `op` \out -> do
    let out' = take (length out - 4) out
    let key = dropDirectory1 out'
    let src' = key -<.> suffix
    let src = if src' == "help.ml" then inOutDir src' else src'
    need [src]
    (_, flags, ppflags) <- oracle $ OcamlCmdLineOracle key
    let flagl = words flags
    let incs = unwords ["-I " ++ d | d <- getincludes flagl
                                   , not $ isabsinc d]
    (Stdout stdout, Stderr emsg, Exit ex) <-
          cmd ocamldep "-one-line" incs ppflags src
    ppppe ex src emsg
    let depo = deps ++ [dep -<.> ".cmo_dep" | dep <- deps, fit dep]
          where
            deps = deplist $ parseMakefile stdout
            fit dep = ext == ".cmi" && base /= baseout
              where (base, ext) = splitExtension dep
                    baseout = dropExtension out
    writeFileChanged out stdout
    need depo
    ordoracle $ OcamlOrdOracle out'
  where (target, suffix, op) = case t of
          CMO -> ("//*.cmo_dep", ".ml", (%>))
          CMI -> ("//*.cmi_dep", ".mli", (%>))
        deplist [] = []
        deplist ((_, reqs) : _) =
          [if takeDirectory1 n == outdir then n else inOutDir n | n <- reqs]

main = do
  depl <- newMVar ([] :: [String])
  shakeArgs shakeOptions { shakeFiles = outdir
                         , shakeVerbosity = Normal
                         , shakeChange = ChangeModtimeAndDigest } $ do
  want ["build/llpp"]

  gitDescribeOracle <- addOracle $ \(GitDescribeOracle ()) -> do
    Stdout out <- cmd "git describe --tags --dirty"
    return (out :: String)

  ocamlOracle <- addOracle $ \(OcamlCmdLineOracle s) ->
    return $ ocamlKey s

  ocamlOrdOracle <- addOracle $ \(OcamlOrdOracle s) -> do
    liftIO $ modifyMVar_ depl $ \l -> return $ s:l

  cOracle <- addOracle $ \(CCmdLineOracle s) -> return $ cKey s

  inOutDir "help.ml" %> \out -> do
    version <- gitDescribeOracle $ GitDescribeOracle ()
    need ["mkhelp.sh", "KEYS"]
    Stdout f <- cmd "/bin/sh mkhelp.sh KEYS" version
    writeFileChanged out f

  "//*.o" %> \out -> do
    let key = dropDirectory1 out
    flags <- cOracle $ CCmdLineOracle key
    let src = key -<.> ".c"
    let dep = out -<.> ".d"
    unit $ cmd ocamlc "-ccopt"
      [flags ++ " -MMD -MF " ++ dep ++ " -o " ++ out] "-c" src
    needMakefileDependencies dep

  inOutDir "llpp" %> \out -> do
    let objs = map (inOutDir . (++) "lablGL/ml_") ["gl.o", "glarray.o", "raw.o"]
    need (objs ++ map inOutDir ["link.o", "main.cmo", "help.cmo"])
    cms <- liftIO $ readMVar depl
    let cmos = nub $ map (-<.> ".cmo") cms
    need cmos
    unit $ cmd ocamlc "-g -custom -I lablGL -o" out
      "unix.cma str.cma" (reverse cmos)
      (inOutDir "link.o") "-cclib" (cclib : objs)

  cm' CMI ocamlOracle
  cm' CMO ocamlOracle
  cm'dep CMI ocamlOracle ocamlOrdOracle
  cm'dep CMO ocamlOracle ocamlOrdOracle
