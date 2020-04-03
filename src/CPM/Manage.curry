------------------------------------------------------------------------------
--- This module implements tools to manage the central repository:
---
--- Run "cpm-manage -h" to see all options.
---
------------------------------------------------------------------------------

module CPM.Manage ( main )
  where

import Directory ( createDirectoryIfMissing, doesDirectoryExist, doesFileExist
                 , getAbsolutePath, getCurrentDirectory, getDirectoryContents )
import FilePath  ( (</>), replaceExtension )
import IOExts    ( evalCmd, readCompleteFile )
import List      ( groupBy, intercalate, isSuffixOf, nub, nubBy, sortBy, sum )
import System    ( getArgs, exitWith, system )
import Time      ( CalendarTime, calendarTimeToString
                 , getLocalTime, toDayString )

import HTML.Base
import HTML.Styles.Bootstrap3  ( bootstrapPage, glyphicon, homeIcon )
import ShowDotGraph
import Text.CSV                ( readCSV, writeCSVFile )

import CPM.Config              ( Config, repositoryDir, packageInstallDir
                               , readConfigurationWith )
import CPM.ErrorLogger
import CPM.FileUtil            ( copyDirectory, inDirectory, tempDir
                               , recreateDirectory
                               , removeDirectoryComplete )
import CPM.Package
import CPM.PackageCache.Global ( acquireAndInstallPackageFromSource
                               , checkoutPackage )
import CPM.Package.Helpers     ( renderPackageInfo )
import CPM.Repository          ( allPackages, listPackages
                               , readPackageFromRepository )
import CPM.Repository.Update   ( addPackageToRepository, updateRepository )
import CPM.Repository.Select   ( getBaseRepository, getPackageVersion )
import CPM.Resolution          ( isCompatibleToCompiler )

import CPM.Manage.Config
import CPM.Package.HTML

------------------------------------------------------------------------------
main :: IO ()
main = do
  args <- getArgs
  case args of
    ["genhtml"]       -> writePackageIndexAsHTML "CPM"
    ["genhtml",d]     -> writePackageIndexAsHTML d
    ["genhtml",d,p,v] -> writePackageVersionAsHTML d p v
    ["gendocs"]       -> generateDocsOfAllPackages packageDocDir
    ["gendocs",d]     -> getAbsolutePath d >>= generateDocsOfAllPackages
    ["gentar"]        -> genTarOfAllPackages packageTarDir
    ["gentar",d]      -> getAbsolutePath d >>= genTarOfAllPackages
    ["testall"]       -> testAllPackages ""
    ["testall",d]     -> getAbsolutePath d >>= testAllPackages
    ["sumcsv",d]      -> do ad <- getAbsolutePath d
                            sumCSVStatsOfPkgs ad "SUM.csv"
    ["add"]           -> addNewPackage True
    ["addnotag"]      -> addNewPackage False
    ["update"]        -> updatePackage
    ["showgraph"]     -> showAllPackageDependencies
    ["writedeps"]     -> writeAllPackageDependencies
    ["copydocs"]      -> copyPackageDocumentations packageDocDir
    ["copydocs",d]    -> getAbsolutePath d >>= copyPackageDocumentations
    ["--help"]        -> putStrLn helpText
    ["-h"]            -> putStrLn helpText
    _                 -> do putStrLn $ "Wrong arguments!\n"
                            putStrLn helpText
                            exitWith 1

helpText :: String
helpText = banner ++ unlines
    [ "Options:", ""
    , "add           : add this package version to the central repository"
    , "                and tag git repository of this package with its version"
    , "addnotag      : add this package version to the central repository"
    , "                (do not tag git repository)"
    , "update        : tag git repository of local package with current version"
    , "                and update central index with current package specification"
    , "genhtml [<d>] : generate HTML pages of central repository into <d>"
    , "                (default: 'CPM')"
    , "genhtml <d> <p> <v>: generate HTML pages for package <p> / version <v>"
    , "                into directory <d>"
    , "gendocs [<d>] : generate HTML documentations of all packages into <d>"
    , "                (default: '" ++ packageDocDir ++ "')"
    , "gentar  [<d>] : generate tar.gz files of all packages into <d>"
    , "                (default: '" ++ packageTarDir ++ "')"
    , "testall [<d>] : test all packages of the central repository"
    , "                and write test statistics into directory <d>"
    , "sumcsv  [<d>] : sum up all CSV package statistic files in <d>"
    , "showgraph     : visualize all package dependencies as dot graph"
    , "writedeps     : write all package dependencies as CSV file 'pkgs.csv'"
    , "copydocs [<d>]: copy latest package documentations"
    , "                from <d> (default: '" ++ packageDocDir ++ "')"
    , "                to '" ++ currygleDocDir ++ "'"
    ]

------------------------------------------------------------------------------
--- Get all packages from the repository.
--- For each package, get the newest version compatible
--- to the current compiler. If there is no compatible version and the
--- first argument is False, get the newest version, otherwise the package
--- is ignored.
--- In addition to this package list (third component),
--- the first component contains the current configuration and the
--- second component the list of all packages grouped by versions
--- (independent of the compiler compatbility).
getAllPackageSpecs :: Bool -> IO (Config,[[Package]],[Package])
getAllPackageSpecs compat = do
  config <- readConfiguration
  putStrLn "Reading base repository..."
  repo <- getBaseRepository config
  let allpkgversions = listPackages repo
      allcompatpkgs  = sortBy (\ps1 ps2 -> name ps1 <= name ps2)
                              (concatMap (filterCompatPkgs config)
                                         allpkgversions)
  return (config,allpkgversions,allcompatpkgs)
 where
  -- Returns the first package compatible to the current compiler.
  -- If `compat` is False and there are no compatible packages,
  -- return the first package.
  filterCompatPkgs cfg pkgs =
    let comppkgs = filter (isCompatibleToCompiler cfg) pkgs
    in if null comppkgs
         then if compat then [] else take 1 pkgs
         else [head comppkgs]

------------------------------------------------------------------------------
-- Generate main HTML index pages of the CPM repository.
writePackageIndexAsHTML :: String -> IO ()
writePackageIndexAsHTML cpmindexdir = do
  createDirectoryIfMissing True cpmindexdir
  inDirectory cpmindexdir $ do
   createDirectoryIfMissing True packageHtmlDir
   system $ "chmod 755 " ++ packageHtmlDir
   (config,allpkgversions,newestpkgs) <- getAllPackageSpecs False
   let stats = pkgStatistics allpkgversions newestpkgs
   putStrLn "Reading all package specifications..."
   allnpkgs <- mapIO (fromErrorLogger . readPackageFromRepository config)
                     newestpkgs
   writePackageIndex allnpkgs "index.html" stats
   allvpkgs <- mapIO (fromErrorLogger . readPackageFromRepository config)
                 (concat
                    (map reverse
                       (sortBy (\pg1 pg2 -> name (head pg1) <= name (head pg2))
                               allpkgversions)))
   writePackageIndex allvpkgs "indexv.html" stats
   writeCategoryIndexAsHTML allnpkgs
   mapIO_ (writePackageAsHTML allpkgversions newestpkgs) allvpkgs
 where
  writePackageIndex allpkgs indexfile statistics = do
    ltime <- getLocalTime
    putStrLn $ "Writing '" ++ indexfile ++ "'..."
    indextable <- packageInfosAsHtmlTable allpkgs
    let ptitle = "Curry Packages in the CPM Repository"
    pagestring <-
      cpmIndexPage ptitle [h1 [htxt ptitle]]
        ([h2 [htxt $ "Version: " ++ toDayString ltime ++ ""], indextable] ++
         statistics)
    writeReadableFile indexfile pagestring

  pkgStatistics allpkgversions newestpkgs =
    [h4 [htxt "Statistics:"],
     par [htxt $ show (length newestpkgs) ++ " packages", breakline,
          htxt $ show (length (concat allpkgversions)) ++ " package versions"]]

-- Generate main category index page.
writeCategoryIndexAsHTML :: [Package] -> IO ()
writeCategoryIndexAsHTML allpkgs = do
  let allcats = sortBy (<=) . nub . concatMap category $ allpkgs
      catpkgs = map (\c -> (c, sortBy pidLeq . nubBy pidEq .
                                 filter (\p -> c `elem` category p) $ allpkgs))
                    allcats
  cattables <- mapM formatCat catpkgs
  let catlinks = map (\ (c,_) -> hrefDfltSm ('#':c) [htxt c]) catpkgs
      hcats = concatMap (\ (c,t) -> [anchor c [htxt ""], hrule, h1 [htxt c], t])
                        cattables
      ptitle = "Curry Package Categories"
  pagestring <- cpmIndexPage ptitle [h1 [htxt ptitle]]
                  (h2 [htxt "All package categories"] : par (hitems catlinks) :
                   hcats)
  writeReadableFile "indexc.html" pagestring
 where
  pidEq p1 p2 = packageId p1 == packageId p2

  pidLeq p1 p2 = packageId p1 <= packageId p2

  formatCat (c,ps) = do
    pstable <- packageInfosAsHtmlTable ps
    return (c, pstable)

--- Standard HTML page for generated a package index.
cpmIndexPage :: String -> [HtmlExp] -> [HtmlExp] -> IO String
cpmIndexPage title htmltitle maindoc = do
  time <- getLocalTime
  return $ showHtmlPage $
    bootstrapPage "bt3" cssIncludes title homeBrand (leftTopMenu False)
                  rightTopMenu 0 [] htmltitle maindoc (curryDocFooter time)

--- Generate HTML page for a package in a given version into a directory.
writePackageVersionAsHTML :: String -> String -> String -> IO ()
writePackageVersionAsHTML cpmindexdir pname pversion = do
  case readVersion pversion of
    Nothing -> error $ "'" ++ pversion ++ "' is not a valid version"
    Just  v -> do
      (cfg,allpkgs,newestpkgs) <- getAllPackageSpecs False
      mbpkg <- getPackageVersion cfg pname v
      case mbpkg of
        Nothing ->
          error $ "Package '" ++ pname ++ "-" ++ pversion ++ "' not found!"
        Just pkg -> do
          fullpkg <- fromErrorLogger $ readPackageFromRepository cfg pkg
          createDirectoryIfMissing True cpmindexdir
          putStrLn $ "Changing to directory '" ++ cpmindexdir ++ "'..."
          inDirectory cpmindexdir $ do
            createDirectoryIfMissing True packageHtmlDir
            system $ "chmod 755 " ++ packageHtmlDir
            writePackageAsHTML allpkgs newestpkgs fullpkg

--- Write HTML page for a package.
writePackageAsHTML :: [[Package]] -> [Package] -> Package -> IO ()
writePackageAsHTML allpkgversions newestpkgs pkg = do
  putStrLn $ "Writing '" ++ htmlfile ++ "'..."
  pagestring <- packageToHTML allpkgversions newestpkgs pkg
  inDirectory packageHtmlDir $ do
    writeReadableFile htmlfile pagestring
    writeReadableFile metafile (renderPackageInfo True True True pkg)
    -- set symbolic link to recent package:
    system $ unwords
      ["/bin/rm", "-f", htmllink, "&&", "ln", "-s", htmlfile, htmllink]
    done
 where
  htmlfile = packageId pkg ++ ".html"
  htmllink = name pkg ++ ".html"
  metafile = packageId pkg ++ ".txt"

--- Writes a file readable for all:
writeReadableFile :: String -> String -> IO ()
writeReadableFile f s = writeFile f s >> system ("chmod 644 " ++ f) >> done

-- Format a list of packages as an HTML table
packageInfosAsHtmlTable :: [Package] -> IO HtmlExp
packageInfosAsHtmlTable pkgs = do
  rows <- mapM formatPkgAsRow pkgs
  return $ borderedHeadedTable
    (map ((:[]) . htxt)
         ["Name", "API", "Doc","Executable","Synopsis", "Version"])
    rows
 where
  formatPkgAsRow :: Package -> IO [[HtmlExp]]
  formatPkgAsRow pkg = do
    hasapi    <- doesDirectoryExist apiDir
    let docref    = maybe [] (\r -> [href r [htxt "PDF"]]) (manualURL pkg)
    return
      [ [hrefPrimSmBlock (packageHtmlDir </> pkgid ++ ".html")
                         [htxt $ name pkg]]
      , if hasapi then [ehref (cpmDocURL ++ pkgid) [htxt "API"]] else [nbsp]
      , if hasapi then docref else [nbsp]
      , [maybe (htxt "")
               (\ (PackageExecutable n _ _) -> kbd [htxt n])
               (executableSpec pkg)]
      , [htxt $ synopsis pkg]
      , [htxt $ showVersion (version pkg)] ]
   where
    pkgid  = packageId pkg
    apiDir = "DOC" </> pkgid

------------------------------------------------------------------------------
-- Generate HTML documentation of all packages in the central repository
generateDocsOfAllPackages :: String -> IO ()
generateDocsOfAllPackages packagedocdir = do
  (_,_,allpkgs) <- getAllPackageSpecs True
  mapIO_ genDocOfPackage allpkgs
 where
  genDocOfPackage pkg = inEmptyTempDir $ do
    let pname = name pkg
        pversion = showVersion (version pkg)
    putStrLn $ unlines [dline, "Documenting: " ++ pname, dline]
    let cmd = unwords [ "rm -rf", pname, "&&"
                      , "cypm","checkout", pname, pversion, "&&"
                      , "cd", pname, "&&"
                      , "cypm", "install", "--noexec", "&&"
                      , "cypm", "doc", "--docdir", packagedocdir
                              , "--url", cpmDocURL, "&&"
                      , "cd ..", "&&"
                      , "rm -rf", pname
                      ]
    putStrLn $ "CMD: " ++ cmd
    system cmd

------------------------------------------------------------------------------
-- Run `cypm test` on all packages of the central repository
testAllPackages :: String -> IO ()
testAllPackages statdir = do
  (_,_,allpkgs) <- getAllPackageSpecs True
  results <- mapIO (checkoutAndTestPackage statdir) allpkgs
  if sum (map fst results) == 0
    then putStrLn $ show (length allpkgs) ++ " PACKAGES SUCCESSFULLY TESTED!"
    else do putStrLn $ "ERRORS OCCURRED IN PACKAGES: " ++
                       unwords (map snd (filter ((> 0) . fst) results))
            exitWith 1

dline :: String
dline = take 78 (repeat '=')

------------------------------------------------------------------------------
-- Generate tar.gz files of all packages (in the current directory)
genTarOfAllPackages :: String -> IO ()
genTarOfAllPackages tardir = do
  createDirectoryIfMissing True tardir
  putStrLn $ "Generating tar.gz of all package versions in '" ++ tardir ++
             "'..."
  (cfg,allpkgversions,_) <- getAllPackageSpecs False
  allpkgs <- mapIO (fromErrorLogger . readPackageFromRepository cfg)
                   (sortBy (\ps1 ps2 -> packageId ps1 <= packageId ps2)
                           (concat allpkgversions))
  mapIO_ (writePackageAsTar cfg) allpkgs --(take 3 allpkgs)
 where
  writePackageAsTar cfg pkg = do
    let pkgname  = name pkg
        pkgid    = packageId pkg
        pkgdir   = tardir </> pkgid
        tarfile  = pkgdir ++ ".tar.gz"
    putStrLn $ "Checking out '" ++ pkgid ++ "'..."
    let checkoutdir = pkgname
    system $ unwords [ "rm -rf", checkoutdir, pkgdir ]
    fromErrorLogger
      (acquireAndInstallPackageFromSource cfg pkg |> checkoutPackage cfg pkg)
    let cmd = unwords [ "cd", checkoutdir, "&&"
                      , "tar", "cvzf", tarfile, ".", "&&"
                      , "chmod", "644", tarfile, "&&"
                      , "cd", "..", "&&", "mv", checkoutdir, pkgdir, "&&"
                      , "chmod", "-R", "go+rX", pkgdir
                      ]
    putStrLn $ "...with command:\n" ++ cmd
    ecode <- system cmd
    when (ecode>0) $ error $ "ERROR OCCURED IN PACKAGE '" ++ pkgid ++ "'!"


------------------------------------------------------------------------------
-- Add a new package (already committed and pushed into its git repo)
-- where the package specification is stored in the current directory.
addNewPackage :: Bool -> IO ()
addNewPackage withtag = do
  config <- readConfiguration
  pkg <- fromErrorLogger (loadPackageSpec ".")
  when withtag $ setTagInGit pkg
  let pkgIndexDir      = name pkg </> showVersion (version pkg)
      pkgRepositoryDir = repositoryDir config </> pkgIndexDir
      pkgInstallDir    = packageInstallDir config </> packageId pkg
  fromErrorLogger $ addPackageToRepository config "." False False
  putStrLn $ "Package repository directory '" ++ pkgRepositoryDir ++ "' added."
  (ecode,_) <- checkoutAndTestPackage "" pkg
  when (ecode>0) $ do
    removeDirectoryComplete pkgRepositoryDir
    removeDirectoryComplete pkgInstallDir
    putStrLn "Checkout/test failure, package deleted in repository directory!"
    updateRepository config True True False
    exitWith 1
  putStrLn $ "\nEverything looks fine..."
  putStrLn $ "\nTo publish the new repository directory, run command:\n"
  putStrLn $ "pushd " ++ repositoryDir config ++
             " && git add " ++ pkgIndexDir </> packageSpecFile ++
             " && git commit -m\"" ++ pkgIndexDir ++ " added\" " ++
             " && git push origin master && popd"

-- Set the package version as a tag in the git repository.
setTagInGit :: Package -> IO ()
setTagInGit pkg = do
  let ts = 'v' : showVersion (version pkg)
  (_,gittag,_) <- evalCmd "git" ["tag","-l",ts] ""
  let deltag = if null gittag then [] else ["git tag -d",ts,"&&"]
      cmd    = unwords $ deltag ++ ["git tag -a",ts,"-m",ts,"&&",
                                    "git push --tags -f"]
  putStrLn $ "Execute: " ++ cmd
  ecode <- system cmd
  when (ecode > 0) $ error "ERROR in setting the git tag"

------------------------------------------------------------------------------
-- Test a specific version of a package by checking it out in a temporary
-- directory, install it (with a local bin dir), and run all tests.
-- Returns the exit code of the package test command and the packaged id.
checkoutAndTestPackage :: String -> Package -> IO (Int,String)
checkoutAndTestPackage statdir pkg = inEmptyTempDir $ do
  putStrLn $ unlines [dline, "Testing package: " ++ pkgid, dline]
  -- create installation bin dir:
  curdir <- getCurrentDirectory
  let bindir = curdir </> "pkgbin"
  recreateDirectory bindir
  let statfile = if null statdir then "" else statdir </> pkgid ++ ".csv"
  unless (null statdir) $ createDirectoryIfMissing True statdir
  let checkoutdir = pkgname
      cmd = unwords $
              [ "rm -rf", checkoutdir, "&&"
              , "cypm", "checkout", pkgname, showVersion pkgversion, "&&"
              , "cd", checkoutdir, "&&"
              -- install possible binaries in bindir:
              , "cypm", "-d bin_install_path=" ++ bindir, "install", "&&"
              , "export PATH=" ++ bindir ++ ":$PATH", "&&"
              , "cypm", "test"] ++
              (if null statfile then [] else ["-f", statfile]) ++
              [ "&&"
              , "cypm", "-d bin_install_path=" ++ bindir, "uninstall"
              ]
  putStrLn $ "...with command:\n" ++ cmd
  ecode <- system cmd
  when (ecode>0) $ putStrLn $ "ERROR OCCURED IN PACKAGE '" ++ pkgid ++ "'!"
  return (ecode,pkgid)
 where
  pkgname     = name pkg
  pkgversion  = version pkg
  pkgid       = packageId pkg

------------------------------------------------------------------------------
-- Combine all CSV statistics files for packages (produced by
-- `cypm test -f ...`) contained in a directory into a result file
-- and sum up the results.
sumCSVStatsOfPkgs :: String -> String -> IO ()
sumCSVStatsOfPkgs dir outfile = do
  combineCSVFilesInDir readStats showResult addStats ([],[]) dir outfile
  putStrLn $ "All results written to file '" ++ outfile ++ "'."
 where
  readStats rows =
    let [pkgid,ct,rc,total,unit,prop,eqv,io,mods] = rows !! 1
    in (rows !! 0,
        [ (pkgid, ct,
           map (\s -> read s :: Int) [rc,total,unit,prop,eqv,io], mods) ])

  showResult (header,rows) =
    header :
    sortBy (<=)
           (map (\(pkgid,ct,nums,mods) -> pkgid : ct : map show nums ++ [mods])
                rows) ++
    ["TOTAL:" : "" :
      map show
          (foldr1 (\nums1 nums2 -> map (uncurry (+)) (zip nums1 nums2))
                  (map (\ (_,_,ns,_) -> ns) rows))]

  addStats (header,rows1) (_,rows2) = (header, rows1 ++ rows2)

-- Combine all CSV files contained in a directory into one result CSV file
-- according to an operation to read the contents of each CSV file,
-- an operation to write the result into CSV format,
-- an operation to combine the results, and a default value.
combineCSVFilesInDir :: ([[String]] -> a) -> (a -> [[String]]) -> (a -> a -> a)
                     -> a -> String -> String -> IO ()
combineCSVFilesInDir fromcsv tocsv combine emptycsv statdir outfile = do
  dcnts <- getDirectoryContents statdir
  let csvfiles = map (statdir </>) (filter (".csv" `isSuffixOf`) dcnts)
  stats <- mapM (\f -> readCompleteFile f >>= return . fromcsv . readCSV)
                csvfiles
  let results = foldr combine emptycsv stats
  writeCSVFile outfile (tocsv results)

------------------------------------------------------------------------------
-- Re-tag the current git version with the current package version
-- and copy the package spec file to the cpm index
updatePackage :: IO ()
updatePackage = do
  config <- readConfiguration
  pkg <- fromErrorLogger (loadPackageSpec ".")
  let pkgInstallDir    = packageInstallDir config </> packageId pkg
  setTagInGit pkg
  putStrLn $ "Deleting old repo copy '" ++ pkgInstallDir ++ "'..."
  removeDirectoryComplete pkgInstallDir
  (ecode,_) <- checkoutAndTestPackage "" pkg
  when (ecode > 0) $ do removeDirectoryComplete pkgInstallDir
                        putStrLn $ "ERROR in package, CPM index not updated!"
                        exitWith 1
  fromErrorLogger $ addPackageToRepository config "." True False

------------------------------------------------------------------------------
-- Show package dependencies as dot graph
showAllPackageDependencies :: IO ()
showAllPackageDependencies = do
  config <- readConfiguration
  pkgs <- getBaseRepository config >>= return . allPackages
  let alldeps = map (\p -> (name p, map (\ (Dependency p' _) -> p')
                                        (dependencies p)))
                    pkgs
      dotgraph = depsToGraph alldeps
  putStrLn $ "Show dot graph..."
  viewDotGraph dotgraph

depsToGraph :: [(String, [String])] -> DotGraph
depsToGraph cpmdeps =
  dgraph "CPM Dependencies"
    (map (\s -> Node s []) (nub (map fst cpmdeps ++ concatMap snd cpmdeps)))
    (map (\ (s,t) -> Edge s t [])
         (nub (concatMap (\ (p,ds) -> map (\d -> (p,d)) ds) cpmdeps)))

-- Write package dependencies into CSV file 'pkgs.csv'
writeAllPackageDependencies :: IO ()
writeAllPackageDependencies = do
  (_,_,pkgs) <- getAllPackageSpecs True
  let alldeps = map (\p -> (name p, map (\ (Dependency p' _) -> p')
                                        (dependencies p)))
                    pkgs
  writeCSVFile "pkgs.csv" (map (\ (p,ds) -> p:ds) alldeps)
  putStrLn $ "Package dependencies written to 'pkgs.csv'"

------------------------------------------------------------------------------
-- Copy all package documentations from directory `packagedocdir` into
-- the directory `currygleDocDir` so that the documentations
-- can be used by Currygle to generate the documentation index
copyPackageDocumentations :: String -> IO ()
copyPackageDocumentations packagedocdir = do
  config <- readConfiguration
  allpkgs <- getBaseRepository config >>= return . allPackages
  let pkgs   = map sortVersions (groupBy (\a b -> name a == name b) allpkgs)
      pkgids = sortBy (\xs ys -> head xs <= head ys) (map (map packageId) pkgs)
  putStrLn $ "Number of package documentations: " ++ show (length pkgs)
  recreateDirectory currygleDocDir
  mapIO_ copyPackageDoc pkgids
 where
  sortVersions ps = sortBy (\a b -> version a `vgt` version b) ps

  copyPackageDoc [] = done
  copyPackageDoc (pid:pids) = do
    let pdir = packagedocdir </> pid
    exdoc <- doesDirectoryExist pdir
    if exdoc
      then do putStrLn $ "Copying documentation of " ++ pid ++ "..."
              copyDirectory pdir (currygleDocDir </> pid)
      else
        if null pids
          then putStrLn $ "Documentation " ++ pid ++ " does not exist!"
          else copyPackageDoc pids

------------------------------------------------------------------------------
--- Reads to the .cpmrc file from the user's home directory and return
--- the configuration. Terminate in case of some errors.
readConfiguration :: IO Config
readConfiguration =
  readConfigurationWith [] >>= \c -> case c of
    Left err -> do putStrLn $ "Error reading .cpmrc file: " ++ err
                   exitWith 1
    Right c' -> return c'

--- Executes an IO action with the current directory set to a new empty
--- temporary directory. After the execution, the temporary directory
--- is deleted.
inEmptyTempDir :: IO a -> IO a
inEmptyTempDir a = do
  tmp <- tempDir
  recreateDirectory tmp
  r  <- inDirectory tmp a
  removeDirectoryComplete tmp
  return r

------------------------------------------------------------------------------
-- The name of the package specification file.
packageSpecFile :: String
packageSpecFile = "package.json"

------------------------------------------------------------------------------
